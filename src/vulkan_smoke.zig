// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runs the host-only Vulkan compute/staging/readback probe.

const std = @import("std");
const vulkan = @import("vulkan");
const gpu = @import("gpu");

comptime {
    @import("host_memory.zig").exportRuntime();
}

const GuestMemory = SizedGuestMemory(131072);

fn SizedGuestMemory(comptime size: usize) type {
    return struct {
        const Self = @This();
        bytes: [size]u8 = @splat(0),

        fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const start: usize = @intCast(address);
            if (start + destination.len > self.bytes.len) return false;
            @memcpy(destination, self.bytes[start..][0..destination.len]);
            return true;
        }

        fn write(context: ?*anyopaque, address: u64, source: []const u8) bool {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const start: usize = @intCast(address);
            if (start + source.len > self.bytes.len) return false;
            @memcpy(self.bytes[start..][0..source.len], source);
            return true;
        }

        fn word(self: *Self, address: usize, value: u32) void {
            std.mem.writeInt(u32, self.bytes[address..][0..4], value, .little);
        }

        fn fingerprint(context: ?*anyopaque, address: u64, length: usize) ?u64 {
            const self: *Self = @ptrCast(@alignCast(context.?));
            if (address > self.bytes.len or length > self.bytes.len - address) return null;
            return gpu.parallel_copy.fingerprint(self.bytes[@intCast(address)..][0..length]);
        }

        fn interface(self: *Self) vulkan.GuestMemory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
}

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
    return vop2Source(opcode, destination, 256 + @as(u9, source0), source1);
}

fn vop2Source(opcode: u8, destination: u8, source0: u9, source1: u8) u32 {
    return (@as(u32, opcode) << 25) |
        (@as(u32, destination) << 17) |
        (@as(u32, source1) << 9) |
        source0;
}

fn sop1(opcode: u8, destination: u8, source: u9) u32 {
    return 0xbe80_0000 | (@as(u32, destination) << 16) | (@as(u32, opcode) << 8) | source;
}

fn sop2(opcode: u7, destination: u7, source0: u8, source1: u8) u32 {
    return 0x8000_0000 | (@as(u32, opcode) << 23) | (@as(u32, destination) << 16) |
        (@as(u32, source1) << 8) | source0;
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
    try runStorageImageCopyCase(allocator, renderer, guest, backend, false);
    try runStorageImageCopyCase(allocator, renderer, guest, backend, true);
}

fn runStorageImageCopyCase(
    allocator: std.mem.Allocator,
    renderer: *vulkan.Renderer,
    guest: *GuestMemory,
    backend: gpu.DcbBackend,
    packed_coordinates: bool,
) !void {
    const program: u32 = if (packed_coordinates) 0x1400 else 0x1800;
    const width = 4;
    const height = 4;
    var program_cursor: usize = program;
    for (0..height) |y| {
        for (0..width) |x| {
            if (packed_coordinates) {
                guest.word(program_cursor, vop1(1, 0, 255));
                guest.word(program_cursor + 4, @intCast(x | (y << 16)));
                // The next VGPR is deliberately outside this 4x4 image.
                guest.word(program_cursor + 8, vop1(1, 1, 192));
                program_cursor += 12;
            } else {
                guest.word(program_cursor, vop1(1, 0, @intCast(128 + x)));
                guest.word(program_cursor + 4, vop1(1, 1, @intCast(128 + y)));
                program_cursor += 8;
            }
            const a16: u32 = if (packed_coordinates) 1 << 30 else 0;
            guest.word(program_cursor, 0xf000_0f08); // image_load v4:v7, v[0:1], s[0:7]
            guest.word(program_cursor + 4, 0x0000_0400 | a16);
            guest.word(program_cursor + 8, 0xf020_0f0a); // image_store v4:v7, v0, s[8:15], NSA v1
            guest.word(program_cursor + 12, 0x0002_0400 | a16);
            guest.word(program_cursor + 16, 0x0000_0001);
            program_cursor += 20;
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
    std.debug.print("storage image coordinate copy passed: {s}\n", .{if (packed_coordinates) "A16 packed X/Y with poisoned adjacent VGPR" else "32-bit X/Y"});
}

fn runSpilledImageDescriptorProbe(allocator: std.mem.Allocator, compact: bool, empty_index: bool) !void {
    for ([_]bool{ false, true }) |skip_spill| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        const guest = try allocator.create(GuestMemory);
        defer allocator.destroy(guest);
        guest.* = .{};
        const program = 0x2000;
        const source = 0x5000;
        const destination = 0x6000;
        const source_words = imageDescriptorWords(source, 4, 4);
        const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(source_words[0..@as(usize, if (compact) 4 else 8)]));
        const surface = try texture.base();
        for ([_][8]u32{ imageDescriptorWords(source, 4, 4), imageDescriptorWords(destination, 4, 4) }, 0..) |descriptor, image_index|
            for (descriptor, 0..) |word, component| guest.word(0x1000 + image_index * 32 + component * 4, word);
        for ([_]u32{ 0xdead0000, 4 << 16, 0, 0 }, 0..) |word, component| guest.word(0x1040 + component * 4, word);
        const indirection = [_]u32{
            0xf408_1400, 0xfa00_0040, // V#s80:s83 has NUM_RECORDS=0
            0xf420_00e8, 2 << 25, // s_buffer_load_dword s3, V#s80, workgroup s2
            0x8703_ff03, 255, // s_and_b32 s3,s3,255
            0x8f03_8503, // s_lshl_b32 s3,s3,5
        };
        const prefix_words: usize = if (empty_index) indirection.len else 0;
        if (empty_index) for (indirection, 0..) |word, index| guest.word(program + index * 4, word);
        const prolog = [_]u32{
            if (compact) 0xf408_0500 else 0xf40c_0500, if (empty_index) 3 << 25 else 0xfa00_0000, // load source T#
            if (compact) 0xf408_1100 else 0xf40c_1100, 0xfa00_0020, // load destination T#
            vop1(1, 0, if (skip_spill) 128 else 129),
            0x7d84_0080, // VCC depends on a VGPR: host scalar walk cannot choose the branch
            0xbf87_000f, // skip all three saves, clobbers and restores
            0xd761_0027, 0x0001_0044, // save s68 in v39 lane 0
            0xd761_0027, 0x0001_0245, // save s69 in v39 lane 1
            0xd761_0027, 0x0001_0446, // save s70 in v39 lane 2
            0xbec4_0380, 0xbec5_0380, 0xbec6_0380, // borrow s68:s70
            0xd760_0044, 0x0001_0127, 0xd760_0045,
            0x0001_0327, 0xd760_0046, 0x0001_0527,
        };
        for (prolog, 0..) |word, index| guest.word(program + (prefix_words + index) * 4, word);
        var cursor: usize = program + (prefix_words + prolog.len) * 4;
        for (0..4) |y| for (0..4) |x| {
            const r128: u32 = if (compact) 1 << 15 else 0;
            const pixel = [_]u32{ vop1(1, 0, @intCast(128 + x)), vop1(1, 1, @intCast(128 + y)), 0xf000_0f08 | r128, 0x0005_0400, 0xf020_0f08 | r128, 0x0011_0400 };
            for (pixel) |word| {
                guest.word(cursor, word);
                cursor += 4;
            }
            const byte: usize = @intCast(try surface.sourceByteOffset(@intCast(x), @intCast(y), 0, 0));
            for (0..4) |component| guest.bytes[source + byte + component] = @intCast(7 + y * 37 + x * 11 + component);
        };
        guest.word(cursor, 0xbf81_0000);
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase(), program >> 8);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, (2 << 1) | (if (empty_index) @as(u32, 1 << 7) else 0));
        for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try state.writeRegister(.shader, reg, 1);
        try state.writeRegister(.shader, compute.userDataBase(), 0x1000);
        try state.writeRegister(.shader, compute.userDataBase() + 1, 0);
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
        _ = try executor.execute(&stream);
        if (renderer.last_dispatch_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (0..4) |y| {
            const byte: usize = @intCast(try surface.sourceByteOffset(0, @intCast(y), 0, 0));
            try std.testing.expectEqualSlices(u8, guest.bytes[source + byte ..][0..16], guest.bytes[destination + byte ..][0..16]);
        }
        std.debug.print("spilled image descriptor passed: R128={}, empty_index={}, {s}, RGBA8 copy verified\n", .{ compact, empty_index, if (skip_spill) "original load path" else "save/borrow/restore path" });
    }
}

fn runSampledStorageRefreshProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |buffer_writer| try runSampledStorageRefreshCase(allocator, buffer_writer);
}

fn runSampledStorageRefreshCase(allocator: std.mem.Allocator, buffer_writer: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    const guest = try allocator.create(SizedGuestMemory(524288));
    defer allocator.destroy(guest);
    guest.* = .{};
    const backend = renderer.dcbBackend(guest.interface());
    const source = 0x6000;
    const output = 0x50000;
    const consumer_program = 0x1400;
    const producer_program = 0x1800;
    const consumer_code = [_]u32{
        vop1(1, 0, 255), @bitCast(@as(f32, 32.5 / 64.0)),
        vop1(1, 1, 255), @bitCast(@as(f32, 32.5 / 64.0)),
        0xf09c_0f0a, 0x0040_0400, 0x0000_0001, // sample RGBA, S#s8
        0xe078_0000, 0x8003_0400, // store four floats through V#s12
        0xbf81_0000,
    };
    const image_code = [_]u32{
        vop1(1, 0, 160), // x=32 in the 128-wide writer
        vop1(1, 1, 144), // y=16: same byte as (32,32) in the 64-wide reader
        vop1(1, 4, 8), // packed RGBA byte value from s8
        0xf020_0108, 0x0000_0400, // image_store R32_UINT
        0xbf81_0000,
    };
    const buffer_code = [_]u32{
        vop1(1, 0, 255), 2080, // dword index of the same texel
        vop1(1, 4, 8), // packed RGBA byte value from s8
        mubuf(0x1c, 0, 4, 0, 0)[0],
        mubuf(0x1c, 0, 4, 0, 0)[1],
        0xbf81_0000,
    };
    const producer_code = if (buffer_writer) &buffer_code else &image_code;
    for (consumer_code, 0..) |word, i| guest.word(consumer_program + i * 4, word);
    for (producer_code, 0..) |word, i| guest.word(producer_program + i * 4, word);
    const compute = gpu.resources.ShaderStage.compute;
    var consumer = gpu.State{};
    var producer = gpu.State{};
    for ([_]*gpu.State{ &consumer, &producer }, 0..) |state, i| {
        try state.writeRegister(.shader, compute.programRegisterBase(), (if (i == 0) @as(u32, consumer_program) else producer_program) >> 8);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, (if (i == 0) @as(u32, 16) else 9) << 1);
        for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try state.writeRegister(.shader, reg, 1);
        var descriptor = if (i == 0) sampledImageDescriptorWords(source, 64, 64) else imageDescriptorWords(source, 128, 32);
        if (i == 1) {
            descriptor[1] = (descriptor[1] & ~(@as(u32, 0x1ff) << 20)) | (20 << 20);
            descriptor[3] = (descriptor[3] & ~@as(u32, 0xfff)) | 4;
            // The default backend defers buffers of at least 256 KiB.
            if (buffer_writer) descriptor = .{ source, 4 << 16, 65536, 0, 0, 0, 0, 0 };
        }
        for (descriptor, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    for (0..4) |i| try consumer.writeRegister(.shader, compute.userDataBase() + 8 + @as(u32, @intCast(i)), 0);
    for ([_]u32{ output, 4 << 16, 4, 0 }, 0..) |word, i| try consumer.writeRegister(.shader, compute.userDataBase() + 12 + @as(u32, @intCast(i)), word);
    const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    var reader = gpu.DcbExecutor{ .state = &consumer, .backend = backend, .allocator = allocator };
    var writer = gpu.DcbExecutor{ .state = &producer, .backend = backend, .allocator = allocator };
    for ([_]u32{ 0, 0x80c0_6020, 0xff19_73e1 }, 0..) |packed_value, phase| {
        if (phase != 0) {
            try producer.writeRegister(.shader, compute.userDataBase() + 8, packed_value);
            _ = try writer.execute(&stream);
            // The first update stays pending; the second is already published.
            // Both must invalidate the old view, even outside its sparse probe.
            try std.testing.expect(std.mem.readInt(u32, guest.bytes[source + 8320 ..][0..4], .little) != packed_value);
            if (phase == 2) {
                try renderer.flushPendingGuestWrites();
                try consumer.writeRegister(.shader, compute.userDataBase() + 8, 2); // another sampler, same view
            }
        }
        for (0..2) |repeat| {
            const misses_before = renderer.texture_cache_misses;
            if (buffer_writer and repeat != 0 and phase != 0) {
                // Binding the unchanged allocation as an SSBO reader does
                // not produce a new texture content epoch.
                _ = try renderer.stageGuestStorageBufferAt(31, source, 65536 * 4);
            }
            _ = try reader.execute(&stream);
            var data: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(output, &data);
            for (0..4) |component| {
                const value: f32 = @bitCast(std.mem.readInt(u32, data[component * 4 ..][0..4], .little));
                const expected = @as(f32, @floatFromInt((packed_value >> @intCast(component * 8)) & 255)) / 255.0;
                try std.testing.expectApproxEqAbs(expected, value, 0.0001);
            }
            if (repeat != 0) try std.testing.expectEqual(misses_before, renderer.texture_cache_misses);
        }
    }
    if (buffer_writer) {
        // Native CPU stores can bypass the command-processor write callback.
        // A later SSBO upload observes this changed byte outside the texture's
        // sparse probe and must invalidate the sampled view in this frame.
        const cpu_value: u32 = 0xff80_c040;
        guest.word(source + 8320, cpu_value);
        _ = try renderer.stageGuestStorageBufferAt(31, source, 65536 * 4);
        _ = try reader.execute(&stream);
        var data: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(output, &data);
        for (0..4) |component| {
            const value: f32 = @bitCast(std.mem.readInt(u32, data[component * 4 ..][0..4], .little));
            const expected = @as(f32, @floatFromInt((cpu_value >> @intCast(component * 8)) & 255)) / 255.0;
            try std.testing.expectApproxEqAbs(expected, value, 0.0001);
        }
    }
    std.debug.print("sampled storage refresh passed: {s} writer, cached UNORM view, pending/published writes, sampler change, unchanged-view reuse and CPU upload\n", .{if (buffer_writer) "buffer" else "image"});
}

fn runPredicatedImageLoadProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const program = 0x1000;
    const source = 0x5000;
    const destination = 0x7000;
    const width = 4;
    const height = 16;
    const pitch = 256;
    const words = [_]u32{
        0x7daa_0080, // v_cmpx_ne_u32 EXEC, 0, v0
        0xbf88_0004, // s_cbranch_execz clear branch
        0xf000_0f08, 0x0000_0400, // image_load v4:v7, v0:v1, T#s0
        0xf020_0f08, 0x0002_0400, // image_store v4:v7, v0:v1, T#s8
        0xbefe_087e, // s_not_b64 EXEC, EXEC
        0xbf88_0006, // s_cbranch_execz end
        vop1(1, 4, 128),
        vop1(1, 5, 128),
        vop1(1, 6, 128),
        vop1(1, 7, 128),
        0xf020_0f08,
        0x0002_0400,
        0xbf81_0000,
    };
    for (words, 0..) |word, index| guest.word(program + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, (16 << 1) | (1 << 11)); // USER_SGPR=16, local X/Y
    try state.writeRegister(.shader, 0x207, width);
    try state.writeRegister(.shader, 0x208, height);
    try state.writeRegister(.shader, 0x209, 1);
    const descriptors = [_][8]u32{
        imageDescriptorWords(source, width, height),
        imageDescriptorWords(destination, width, height),
    };
    for (descriptors, 0..) |descriptor, index| {
        for (descriptor, 0..) |word, component| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index * 8 + component)), word);
        }
    }
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    // Reuse the translated shader and image views with different input bytes.
    for (0..2) |pass| {
        for (0..height) |y| {
            for (0..width * 4) |byte| {
                guest.bytes[source + y * pitch + byte] = @intCast(((y * width * 4 + byte) * 13 + 7 + pass * 41) & 0xff);
            }
        }
        @memset(guest.bytes[destination .. destination + pitch * height], 0xa5);
        _ = try executor.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 });
        if (renderer.last_dispatch_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (0..height) |y| {
            for (0..width * 4) |byte| {
                const expected: u8 = if (byte < 4) 0 else guest.bytes[source + y * pitch + byte];
                try std.testing.expectEqual(expected, guest.bytes[destination + y * pitch + byte]);
            }
        }
    }
    std.debug.print("predicated image loads passed: 64 lanes, CMPX copy, complementary clear, and refreshed input\n", .{});
}

fn runTrigonometricProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const inputs = [_]f32{
        0,                 -0.0,               0.25,              -0.25,   0.5,      -0.5,      0.75,                   -0.75,
        1,                 -1,                 0.125,             -0.125,  0.375,    -0.375,    0.1375,                 -0.1375,
        17.125,            -17.125,            255.25,            -255.25, 4096.375, -4096.375, std.math.floatMax(f32), -std.math.floatMax(f32),
        std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32),
    };
    const load = mubuf(0x0c, 0, 1, 0, 0);
    const store = mubuf(0x1d, 0, 2, 0, 4);
    const words = [_]u32{
        load[0], load[1],
        vop1(53, 2, 257), // v_sin_f32 v2, v1
        vop1(54, 3, 257), // v_cos_f32 v3, v1
        store[0],
        store[1],
        0xbf81_0000,
    };
    for (words, 0..) |word, index| guest.word(0x1000 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 0x10);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    try state.writeRegister(.shader, 0x207, inputs.len);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    const descriptors = [_][4]u32{
        .{ 0x5000, 4 << 16, inputs.len, 0 },
        .{ 0x6000, 8 << 16, inputs.len, 0 },
    };
    for (descriptors, 0..) |descriptor, index| {
        for (descriptor, 0..) |word, component| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index * 4 + component)), word);
        }
    }
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    for (0..2) |pass| {
        for (inputs, 0..) |input, index| guest.word(0x5000 + index * 4, @bitCast(if (pass == 0) input else -input));
        _ = try executor.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 });
        if (renderer.last_dispatch_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (inputs, 0..) |input, index| {
            const value = if (pass == 0) input else -input;
            const actual = [2]f32{
                @bitCast(std.mem.readInt(u32, guest.bytes[0x6000 + index * 8 ..][0..4], .little)),
                @bitCast(std.mem.readInt(u32, guest.bytes[0x6004 + index * 8 ..][0..4], .little)),
            };
            if (!std.math.isFinite(value)) {
                try std.testing.expect(std.math.isNan(actual[0]) and std.math.isNan(actual[1]));
                continue;
            }
            const turns: f64 = value - @trunc(value);
            const angle = turns * (2 * std.math.pi);
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(@sin(angle))), actual[0], 0.000003);
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(@cos(angle))), actual[1], 0.000003);
            if (value == 0) try std.testing.expectEqual(@as(u32, @bitCast(value)), @as(u32, @bitCast(actual[0])));
            if (@abs(turns) == 0.25 or @abs(turns) == 0.75) try std.testing.expectEqual(@as(f32, 0), actual[1]);
            if (@abs(value) == std.math.floatMax(f32)) try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(actual[0])));
        }
    }
    std.debug.print("trigonometry passed: turns, exact quadrants, signed zero, large finite inputs, NaN/Inf and changed inputs\n", .{});
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

fn multiplyScalar(destination: u8, scalar: u8, vector: u8) u32 {
    return (8 << 25) | (@as(u32, destination) << 17) |
        (@as(u32, vector) << 9) | @as(u32, scalar);
}

fn runFragmentScalarReuseProbe(
    allocator: std.mem.Allocator,
    renderer: *vulkan.Renderer,
    guest: *GuestMemory,
    backend: gpu.DcbBackend,
    state: *gpu.State,
    color_address: usize,
) !void {
    const program = 0xc000;
    const table = 0xc400;
    const source = 0xc800;
    const buffer = 0xc700;
    guest.word(source, 0xffff_ffff);
    guest.word(buffer, 0x3f00_0000);
    for (sampledImageDescriptorWords(source, 1, 1), 0..) |word, index| guest.word(table + index * 4, word);
    for (0..4) |index| guest.word(table + 32 + index * 4, 0);
    for ([_]u32{ buffer, 4 << 16, 1, 0 }, 0..) |word, index| guest.word(table + 96 + index * 4, word);
    for (0..8) |index| guest.word(table + 48 + index * 4, 0x3f80_0000);
    for (0..4) |index| {
        guest.word(table + 80 + index * 4, 0x3f80_0000);
        guest.word(table + 112 + index * 4, 0x3f80_0000);
    }
    guest.word(table + 52, 0x3f00_0000);
    guest.word(table + 56, 0x3f40_0000);
    const code = [_]u32{
        0xf40c_0200, 125 << 25, // T# s8:s15
        0xf408_0400, (125 << 25) | 32, // S# s16:s19
        0xf408_0600,     (125 << 25) | 96, // V# s24:s27
        vop1(1, 0, 240), vop1(1, 1, 240),
        0xf09c_0f08, 0x0082_0400, // sample white into v4:v7
        0xe030_0000, 0x8006_0800, // load multiplier v8 from V#s24
        0xf40c_0200, (125 << 25) | 48, // same T# registers now hold color constants
        0xf408_0400, (125 << 25) | 80, // same S# registers now hold scale
        0xf408_0600,              (125 << 25) | 112, // same V# registers now hold scale
        0xbf8c_007f,              multiplyScalar(4, 8, 4),
        multiplyScalar(5, 9, 5),  multiplyScalar(6, 10, 6),
        multiplyScalar(7, 11, 7), multiplyScalar(4, 16, 4),
        multiplyScalar(5, 17, 5), multiplyScalar(6, 18, 6),
        multiplyScalar(7, 19, 7), multiplyScalar(4, 24, 4),
        multiplyScalar(5, 25, 5), multiplyScalar(6, 26, 6),
        multiplyScalar(7, 27, 7),
        vop2(8, 4, 4, 8), // red also consumes the real buffer load
        0xf800_080f,
        0x0706_0504,
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(program + index * 4, word);
    const pixel = gpu.resources.ShaderStage.pixel;
    try state.writeRegister(.shader, pixel.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, pixel.userDataBase() - 1, 2 << 1);
    try state.writeRegister(.shader, pixel.userDataBase(), table);
    try state.writeRegister(.shader, pixel.userDataBase() + 1, 0);
    var executor = gpu.DcbExecutor{ .state = state, .backend = backend, .allocator = allocator };
    var first_misses: u64 = 0;
    for ([_]u32{ 0x3e80_0000, 0x3f40_0000 }, 0..) |red, iteration| {
        // Streaming a different guest texture must also reuse the pipeline.
        const texture_address = source + iteration * 256;
        guest.word(texture_address, 0xffff_ffff);
        guest.word(table, @intCast(texture_address >> 8));
        guest.word(table + 48, red);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error != null) return error.FragmentScalarReuseRejected;
        try renderer.flushPendingGuestWrites();
        const result = guest.bytes[color_address + (32 * 64 + 32) * 4 ..][0..4];
        const expected: [4]u8 = .{ if (iteration == 0) 32 else 96, 128, 191, 255 };
        std.debug.print("fragment reused scalar registers: {any}\n", .{result});
        for (result, expected) |actual, wanted| try std.testing.expect(@abs(@as(i32, actual) - @as(i32, wanted)) <= 1);
        if (iteration == 0) first_misses = renderer.graphics_pipeline_cache_misses else try std.testing.expectEqual(first_misses, renderer.graphics_pipeline_cache_misses);
    }
    std.debug.print("fragment scalar reuse passed: T#/S#/V# lifetimes, streamed textures, dynamic colors and stable pipeline\n", .{});
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

    const feedback_descriptor = sampledImageDescriptorWords(@intCast(color_address), extent, extent);
    const feedback_code = [_]u32{
        0xc801_0000,      0xc805_0100,
        vop1(1, 5, 255),  0x4280_0000,
        vop2(8, 2, 0, 5), vop2(8, 3, 1, 5),
        vop1(7, 2, 258),  vop1(7, 3, 259),
        0xf000_0f08, 0x0000_0402, // read the prior RGBA attachment texel
        0xbf8c_3f70,
        vop1(1, 8, 8), vop2(3, 4, 4, 8), // add .25 to its red channel
        0xf800_080f,   0x0706_0504,
        0xbf81_0000,
    };
    const feedback_program = 0xd400;
    for (feedback_code, 0..) |word, index| guest.word(feedback_program + index * 4, word);
    try state.writeRegister(.shader, pixel.programRegisterBase(), feedback_program >> 8);
    for (feedback_descriptor, 0..) |word, index| try state.writeRegister(.shader, pixel.userDataBase() + @as(u32, @intCast(index)), word);
    try state.writeRegister(.shader, pixel.userDataBase() + 8, 0x3e80_0000);
    // Each queued draw must snapshot the output of the preceding draw, without
    // aliasing the active attachment or reading a stale guest-memory copy.
    for (0..3) |_| {
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error != null) return error.FragmentStorageFeedbackRejected;
    }
    try renderer.flushPendingGuestWrites();
    for ([_]usize{ 24, 40 }) |x| {
        const value = guest.bytes[color_address + (32 * extent + x) * 4 ..][0..4];
        std.debug.print("fragment attachment snapshot result x={d}: {any}\n", .{ x, value });
        try std.testing.expect(value[0] >= 190 and value[0] <= 193);
        try std.testing.expectEqualSlices(u8, &.{ 0, 255, 255 }, value[1..4]);
    }
    std.debug.print("fragment attachment snapshots passed: three queued reads and exports consume each preceding GPU result\n", .{});

    // Keep the old 64x64 blue attachment resident, then render red into a
    // smaller view of the same guest allocation. Storage reads must see the
    // latest raster output, including when the consumer requests the old extent.
    const resized_program = 0xd800;
    const red_code = [_]u32{
        vop1(1, 0, 242), vop1(1, 1, 128),
        vop1(1, 2, 128), vop1(1, 3, 242),
        0xf800_080f,     0x0302_0100,
        0xbf81_0000,
    };
    for (red_code, 0..) |word, index| guest.word(resized_program + index * 4, word);
    try state.writeRegister(.shader, pixel.programRegisterBase(), resized_program >> 8);
    try state.writeRegister(.context, 0x319, 3);
    try state.writeRegister(.context, 0x3b0, (31 << 14) | 31);
    try state.writeRegister(.context, 0x00d, 32 | (32 << 16));
    try state.writeRegister(.context, 0x095, 32 | (32 << 16));
    _ = try executor.execute(&stream);
    if (renderer.last_draw_error != null) return error.ResizedStorageSourceDrawFailed;

    const consumer_program = 0xdc00;
    const buffer = 0x18000;
    const load_code = [_]u32{
        vop1(1, 0, 144), vop1(1, 1, 144), // (16,16)
        0xf000_0f08, 0x0000_0400, // image_load RGBA -> v4:v7
        0xe078_0000, 0x8002_0400, // buffer_store_dwordx4 -> V#s8
        0xbf81_0000,
    };
    for (load_code, 0..) |word, index| guest.word(consumer_program + index * 4, word);
    var consumer_state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try consumer_state.writeRegister(.shader, compute.programRegisterBase(), consumer_program >> 8);
    try consumer_state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try consumer_state.writeRegister(.shader, 0x213, 12 << 1);
    for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try consumer_state.writeRegister(.shader, reg, 1);
    for ([_]u32{ buffer, 4 << 16, 4, 0 }, 0..) |word, index|
        try consumer_state.writeRegister(.shader, compute.userDataBase() + 8 + @as(u32, @intCast(index)), word);
    var consumer = gpu.DcbExecutor{ .state = &consumer_state, .backend = backend, .allocator = allocator };
    for ([_]u32{ 32, 64 }) |consumer_extent| {
        const image = sampledImageDescriptorWords(@intCast(color_address), consumer_extent, consumer_extent);
        for (image, 0..) |word, index|
            try consumer_state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        const translated_before = renderer.translated_dispatches;
        _ = try consumer.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 });
        try std.testing.expectEqual(translated_before + 1, renderer.translated_dispatches);
        var readback: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(buffer, &readback);
        for ([_]f32{ 1, 0, 0, 1 }, 0..) |expected, component| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, readback[component * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        std.debug.print("resized storage attachment passed: newest 32x32 raster output, {d}x{d} consumer\n", .{ consumer_extent, consumer_extent });
    }
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
    const backend = renderer.dcbBackend(guest.interface());
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
    // Replacing the first resident view shifts the second view's cache index.
    // Both changed texels must be uploaded, then found without another upload.
    try std.testing.expect(backend.vtable.write(backend.context, 0x8000, &.{ 128, 0, 0, 255 }));
    try std.testing.expect(backend.vtable.write(backend.context, 0x9000, &.{ 192, 0, 0, 255 }));
    for (0..2) |_| {
        _ = try renderer.dispatchRdna2State(&state, .{ 4, 1, 1 }, .{ 1, 1, 1 });
        try renderer.readbackGuestStorageBuffer(0x3000, &pixels);
        for (0..4) |i| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, pixels[i * 4 ..][0..4], .little));
            const expected: f32 = if (i < 2) 192.0 / 255.0 else 128.0 / 255.0;
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
        try std.testing.expectEqual(@as(u64, 4), renderer.sampled_image_uploads);
    }
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
    try runRepeatedScalarLoadProbe(allocator);
    std.debug.print("scalar loops passed: EXEC masks, inactive lanes and post-loop loads after repeated SMEM reads\n", .{});
}

fn runRepeatedScalarLoadProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0xb008_0000,
        0xf400_0300,
        125 << 25,
        0xf400_0340,
        (125 << 25) | 4,
        0xf400_0380,
        (125 << 25) | 8,
        0xf400_03c0,
        (125 << 25) | 12,
        0x8008_8108, 0xbf0a_b208, 0xbf85_fff5, // 50 iterations, 200 SMEM observations
        0xf400_0300,    (125 << 25) | 16, // late value must replace the loop's s12
        vop1(1, 1, 12), vop1(1, 2, 8),
        0xe074_2000, 0x8001_0100, // store value and completed iteration count
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x9000, 0, 0, 0, 0x10000, 8 << 16, 64, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
    for (0..4) |i| guest.word(0x9000 + i * 4, @intCast(11 + i));
    for ([_]u32{ 0x12345678, 0x87654321 }) |expected| {
        guest.word(0x9010, expected);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var output: [512]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        for (0..64) |lane| {
            try std.testing.expectEqual(expected, std.mem.readInt(u32, output[lane * 8 ..][0..4], .little));
            try std.testing.expectEqual(@as(u32, 50), std.mem.readInt(u32, output[lane * 8 + 4 ..][0..4], .little));
        }
    }
}

fn runDistinctScalarLoadProbe(allocator: std.mem.Allocator) !void {
    const count = 320;
    const lanes = 64;
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    const guest = try allocator.create(SizedGuestMemory(262144));
    defer allocator.destroy(guest);
    guest.* = .{};
    _ = renderer.dcbBackend(guest.interface());
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    for (0..count) |index| {
        try code.appendSlice(allocator, &.{
            0xf400_0300,             (125 << 25) | @as(u32, @intCast(index * 4)), // distinct load into s12
            vop1(1, 1, 12),          vop1(1, 2, 255),
            @intCast(index * lanes),
            vop2(0x25, 2, 0, 2), // v2 = lane + index * 64
        });
        try code.appendSlice(allocator, &mubuf(0x1c, 0, 1, 2, 4));
    }
    try code.append(allocator, 0xbf81_0000);
    for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x9000, 0, 0, 0, 0x10000, 4 << 16, count * lanes, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
    const output = try allocator.alloc(u8, count * lanes * 4);
    defer allocator.free(output);
    for ([_]u32{ 0x12340000, 0x89ab0000 }, 0..) |seed, pass| {
        for (0..count) |index| guest.word(0x9000 + index * 4, seed + @as(u32, @intCast(index * 257 + 1)));
        const report = try renderer.dispatchRdna2State(&state, .{ lanes, 1, 1 }, .{ 1, 1, 1 });
        try std.testing.expect(report.spirv_words != 0);
        if (pass != 0) try std.testing.expect(report.pipeline_cache_hit);
        try renderer.readbackGuestStorageBuffer(0x10000, output);
        for (0..count) |index| {
            const expected = seed + @as(u32, @intCast(index * 257 + 1));
            for (0..lanes) |lane| {
                const actual = std.mem.readInt(u32, output[(index * lanes + lane) * 4 ..][0..4], .little);
                if (actual != expected) std.debug.print("distinct scalar load {d} lane {d}: expected={x} actual={x}\n", .{ index, lane, expected, actual });
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
    std.debug.print("distinct scalar loads passed: 320 reused-SGPR loads, 64 lanes and changed input through one pipeline\n", .{});
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

fn runVectorCarryProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const inputs = [_][2]u32{
        .{ 0x0307_7900, 0xa8 },        .{ 0xffff_ffff, 1 }, .{ 0x8000_0000, 0x8000_0000 },
        .{ 0, 1 },                     .{ 1, 0 },           .{ 0x8000_0000, 0 },
        .{ 0xffff_ffff, 0xffff_ffff }, .{ 0, 0 },
    };
    var case: u32 = 0;
    for ([_]u32{ 64, 512 }) |lanes| for ([_]u32{ 0x30f, 0x310, 0x319 }) |opcode| for ([_]u32{ 106, 12 }) |sdst| for ([_]u64{ 0xffff_ffff_ffff_ffff, 0xaaaa_aaaa_5555_5555 }) |exec| {
        const program = 0x100 + case * 0x100;
        case += 1;
        const code = [_]u32{
            mubuf(0x0d, 0, 2, 0, 0)[0],                    mubuf(0x0d, 0, 2, 0, 0)[1],
            if (lanes == 64) 0xd760_000a else 0xbf80_0000,
            if (lanes == 64) 258 | (191 << 9) else 0xbf80_0000, // require a complete cross-half wave mask
            vop1(1, 7, 256), // preserve local index while destinations overlap v2:v3
            sop1(4, 106, 193), // stale all-one VCC must not survive a carry-out instruction
            sop1(4, 126, 20),
            0xd400_0002 | (opcode << 16) | (sdst << 8),
            258 | (259 << 9),
            0xd528_1003,                    128 | (8 << 9) | (sdst << 18), // high = 0x20 + carry/borrow
            sop1(4, 126, 193),              vop1(1, 4, @intCast(sdst)),
            vop1(1, 5, @intCast(sdst + 1)), mubuf(0x1e, 0, 2, 7, 4)[0],
            mubuf(0x1e, 0, 2, 7, 4)[1],     0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(program + index * 4, word);
        for (0..lanes) |lane| for (inputs[lane % inputs.len], 0..) |word, component|
            guest.word(0x10000 + lane * 8 + component * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, program >> 8);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, 24 << 1);
        var ud: [24]u32 = @splat(0);
        @memcpy(ud[0..9], &[_]u32{ 0x10000, 8 << 16, lanes, 0, 0x12000, 16 << 16, lanes, 0, 0x20 });
        ud[20] = @truncate(exec);
        ud[21] = @truncate(exec >> 32);
        for (ud, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ lanes, 1, 1 }, .{ 1, 1, 1 });
        var output: [512 * 16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x12000, output[0 .. lanes * 16]);
        var mask: u64 = 0;
        for (0..64) |lane| {
            const a, const b = inputs[lane % inputs.len];
            const carry = if (opcode == 0x30f) @as(u64, a) + b > 0xffff_ffff else if (opcode == 0x310) a < b else b < a;
            if (carry and exec & (@as(u64, 1) << @intCast(lane)) != 0) mask |= @as(u64, 1) << @intCast(lane);
        }
        for (0..lanes) |lane| {
            const a, const b = inputs[lane % inputs.len];
            const active = exec & (@as(u64, 1) << @intCast(lane % 64)) != 0;
            const low = if (!active) a else if (opcode == 0x30f) a +% b else if (opcode == 0x310) a -% b else b -% a;
            const high = if (!active) b else 0x20 + @as(u32, @intCast((mask >> @intCast(lane % 64)) & 1));
            const lane_mask: u32 = if (mask & (@as(u64, 1) << @intCast(lane % 64)) != 0) 0xffff_ffff else 0;
            const expected = [_]u32{ low, high, if (lanes == 64) @truncate(mask) else lane_mask, if (lanes == 64) @truncate(mask >> 32) else lane_mask };
            for (expected, 0..) |word, component| {
                const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                if (word != actual) std.debug.print("carry case={d} lanes={d} opcode={x} SDST={d} lane={d} component={d}\n", .{ case, lanes, opcode, sdst, lane, component });
                try std.testing.expectEqual(word, actual);
            }
        }
    };
    std.debug.print("vector carry-out passed: add/sub/subrev, VCC/SGPR masks, stale carry, unsigned overflow/borrow, overlapping operands and 64/512 lanes\n", .{});
}

fn runWave32MaskProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    var case: u32 = 0;
    for ([_]u32{ 32, 64, 512 }) |lanes| for ([_]u8{ 107, 12, 13 }) |sdst| {
        case += 1;
        const neighbor: u8 = if (sdst == 107) 106 else sdst + 1;
        const code = [_]u32{
            0x3602_009f, // v1 = v0 & 31
            vop1(1, 2, 144),
            vop1(1, 3, 170),
            sop1(3, neighbor, 255),
            777,
            sop1(3, 126, 255),
            0x5555_5555,
            sop1(3, 127, 255),          0xaaaa_aaaa, // ignored by wave32 lane selection
            0x7d82_04f9,                0x0606_8001 | (@as(u32, sdst) << 8),
            sop1(0x3c, 20, sdst),       vop1(1, 3, 129),
            sop1(3, 126, 193),          vop1(1, 4, sdst),
            vop1(1, 5, neighbor),       mubuf(0x1f, 0, 3, 0, 0)[0],
            mubuf(0x1f, 0, 3, 0, 0)[1], 0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(case * 256 + index * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, case);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x207, lanes);
        try state.writeRegister(.shader, 0x208, 1);
        try state.writeRegister(.shader, 0x209, 1);
        try state.writeRegister(.shader, 0x213, 4 << 1);
        for ([_]u32{ 0x10000, 12 << 16, lanes, 0 }, 0..) |word, index|
            try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        const packet_words = [_]u32{ 0xc003_1502, 1, 1, 1, 0x8041 };
        var walker = gpu.pm4.Walker.init(&packet_words);
        try std.testing.expect(backend.vtable.dispatch.?(backend.context, &state, (try walker.next()).?));
        if (renderer.last_dispatch_error) |err| return err;
        var output: [512 * 12]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, output[0 .. lanes * 12]);
        for (0..lanes) |lane| {
            const active = lane % 32 < 16 and lane % 2 == 0;
            const expected = [_]u32{ if (active) 1 else 42, if (active) 0xffff_ffff else 0, 777 };
            for (expected, 0..) |word, component| {
                const actual = std.mem.readInt(u32, output[lane * 12 + component * 4 ..][0..4], .little);
                if (actual != word) std.debug.print("wave32 case={d} SDST={d} lane={d} component={d}\n", .{ case, sdst, lane, component });
                try std.testing.expectEqual(word, actual);
            }
        }
    };
    std.debug.print("wave32 masks passed: dispatch initiator, VCC_HI, odd SGPRs, neighboring words and repeated low EXEC across 32/64/512 invocations\n", .{});
}

fn runSaveExecProbe(allocator: std.mem.Allocator) !void {
    const pairs = [_][2]u64{
        .{ 0xaaaa_aaaa_5555_5555, 0xcccc_cccc_3333_3333 },
        .{ 0xffff_ffff_ffff_ffff, 0 },
        .{ 0xffff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff },
        .{ 0, 0xffff_ffff_ffff_ffff },
        .{ 0xffff_ffff_0000_0000, 0 },
    };
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var case: u32 = 0;
    for ([_]u32{ 64, 512 }) |lanes| for ([_]u8{ 0x24, 0x28, 0x37, 0x3c, 0x44 }) |opcode| for (pairs) |pair| {
        case += 1;
        const narrow = opcode == 0x3c or opcode == 0x44;
        const code = [_]u32{
            if (lanes == 64) 0xd760_0018 else 0xbf80_0000,
            if (lanes == 64) 256 | (191 << 9) else 0xbf80_0000,
            vop1(1, 2, 170),
            sop1(4, 126, 8),
            sop1(opcode, 10, 10), // destination overlaps the source pair
            0x8514_8081, // capture SCC before restoring EXEC
            vop1(1, 2, 129),
            sop1(4, 126, 193),
            vop1(1, 3, 10),
            vop1(1, 4, 11),
            vop1(1, 5, 20),
            mubuf(0x1e, 0, 2, 0, 0)[0],
            mubuf(0x1e, 0, 2, 0, 0)[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(case * 256 + index * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, case);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, 12 << 1);
        const userdata = [_]u32{ 0x10000, 16 << 16, lanes, 0, 0, 0, 0, 0, @truncate(pair[0]), @truncate(pair[0] >> 32), @truncate(pair[1]), @truncate(pair[1] >> 32) };
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ lanes, 1, 1 }, .{ 1, 1, 1 });
        var output: [512 * 16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, output[0 .. lanes * 16]);
        const combined = if (opcode == 0x28) pair[1] | ~pair[0] else if (opcode == 0x37 or opcode == 0x44) ~pair[1] & pair[0] else pair[1] & pair[0];
        const active = if (narrow) (pair[0] & 0xffff_ffff_0000_0000) | (combined & 0xffff_ffff) else combined;
        const scc: u32 = @intFromBool(if (narrow) combined & 0xffff_ffff != 0 else combined != 0);
        for (0..lanes) |lane| {
            const expected = [_]u32{
                if (active & (@as(u64, 1) << @intCast(lane % 64)) != 0) 1 else 42,
                @truncate(pair[0]),
                @truncate((if (narrow) pair[1] else pair[0]) >> 32),
                scc,
            };
            for (expected, 0..) |word, component| {
                const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                if (word != actual) std.debug.print("saveexec case={d} lanes={d} opcode={x} lane={d} component={d}\n", .{ case, lanes, opcode, lane, component });
                try std.testing.expectEqual(word, actual);
            }
        }
    };
    std.debug.print("SAVEEXEC passed: AND/ANDN1/ORN2 operand order, saved masks, overlapping destinations, SCC and preserved EXEC_HI for 32-bit operations\n", .{});
}

fn runBufferCompactionProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const atomic = mubuf(0x32, 0, 2, 0, 4);
    const store = mubuf(0x1c, 0, 0, 3, 8);
    // Reserve one dense range per guest wave, then distribute it among its
    // active lanes. The cutoff and parity produce sparse and high-only masks.
    const code = [_]u32{
        vop2Source(0x1b, 1, 129, 0), // parity = lane & 1
        0x7da6_0000, // CMPX LE s0, v0
        0x7da4_0280, // CMPX EQ 0, v1
        sop1(4, 12, 126), // save EXEC
        sop1(0x10, 14, 126), // population of both EXEC halves
        0xd766_0003, 127 | (128 << 9), // rank high
        0xd765_0003,     126 | (259 << 9), // rank low
        vop1(1, 2, 128),
        0x7da4_0680, // only rank zero performs the atomic
        vop1(1, 2, 14),
        (atomic[0] & ~@as(u32, 1 << 13)) | (1 << 14),
        atomic[1],
        sop1(4, 126, 12), // restore participating lanes
        vop1(2, 15, 258), // broadcast the returned base
        vop2Source(0x25, 3, 15, 3), // output index = base + rank
        store[0],
        store[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 12 << 1);
    for ([_]u32{ 0, 1, 35, 62, 64 }) |cutoff| for ([_]u32{ 1, 3 }) |groups| {
        const counter_address = 0x10000;
        const output_address = 0x11000;
        guest.word(counter_address, 7);
        for (0..256) |word| guest.word(output_address + word * 4, 0xcccc_cccc);
        for ([_]u32{ cutoff, 0, 0, 0, counter_address, 4 << 16, 1, 0, output_address, 4 << 16, 256, 0 }, 0..) |word, index| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ groups, 1, 1 });
        var counter: [4]u8 = undefined;
        var output: [1024]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(counter_address, &counter);
        try renderer.readbackGuestStorageBuffer(output_address, &output);
        const first = (cutoff + 1) & ~@as(u32, 1);
        const count = (64 - first) / 2 * groups;
        const actual_count = std.mem.readInt(u32, &counter, .little);
        if (actual_count != 7 + count) std.debug.print("compaction cutoff={d} groups={d}: expected count={d}, actual={d}\n", .{ cutoff, groups, 7 + count, actual_count });
        try std.testing.expectEqual(7 + count, actual_count);
        var occurrences: [64]u32 = @splat(0);
        for (0..256) |index| {
            const value = std.mem.readInt(u32, output[index * 4 ..][0..4], .little);
            if (index < 7 or index >= 7 + count) {
                try std.testing.expectEqual(@as(u32, 0xcccc_cccc), value);
            } else {
                try std.testing.expect(value < 64 and value >= cutoff and value % 2 == 0);
                occurrences[value] += 1;
            }
        }
        for (occurrences, 0..) |actual, lane| {
            try std.testing.expectEqual(if (lane >= cutoff and lane % 2 == 0) groups else @as(u32, 0), actual);
        }
    };
    std.debug.print("buffer compaction passed: sparse/high-only/empty wave64 masks, exact counts, dense indices, concurrent waves and preserved padding\n", .{});
}

fn runBufferAtomicProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const types = [_]gpu.shader_analysis.Opcode{ .buffer_atomic_add, .buffer_atomic_fmin, .buffer_atomic_fmax };
    for ([_]bool{ false, true }) |typed_ir| for (types) |opcode| for ([_]bool{ false, true }) |wave32| for ([_]u32{ 0, 35, 128 }) |selected| for ([_]u16{ 32, 64 }) |offset| for ([_]bool{ false, true }) |returns| {
        const initial: u32 = if (opcode == .buffer_atomic_add) 10 else @bitCast(@as(f32, 10));
        const input: u32 = switch (opcode) {
            .buffer_atomic_add => 1,
            .buffer_atomic_fmin => @bitCast(@as(f32, -20)),
            .buffer_atomic_fmax => @bitCast(@as(f32, 20)),
            else => unreachable,
        };
        // Inactive invocations keep an unrelated value, as in Yotei's masked
        // counter update. Predicating the returned VGPR alone cannot protect
        // the shared counter from their side effects.
        const poison: u32 = 0xb7e9_3b83;
        const atomic = mubuf(switch (opcode) {
            .buffer_atomic_add => 0x32,
            .buffer_atomic_fmin => 0x3f,
            .buffer_atomic_fmax => 0x40,
            else => unreachable,
        }, @intCast(offset), 1, 0, 4);
        const output = mubuf(0x1c, 0, 1, 0, 8);
        const code = [_]u32{
            vop1(1, 1, 255), poison,
            0x7d84_00ff,       selected, // v_cmp_eq_u32 vcc, selected, v0
            sop1(4, 126, 106), vop1(1, 1, 255),
            input,             (atomic[0] & ~@as(u32, 1 << 13)) | (if (returns) @as(u32, 1 << 14) else 0),
            atomic[1],         sop1(4, 126, 193),
            output[0],         output[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        var analysis = try gpu.shader_analysis.decodeWithOptions(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 64, .{ .enable_typed_ir = typed_ir });
        defer analysis.deinit(allocator);
        try std.testing.expectEqual(opcode, analysis.program.instructions.items[4].opcode);
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .wave32 = wave32,
            .local_size = .{ 128, 1, 1 },
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{
                .{ .resource_sgpr = 4, .descriptor_index = 0, .extent_bytes = 64 },
                .{ .resource_sgpr = 8, .descriptor_index = 1, .extent_bytes = 512, .stride = 4 },
            },
        });
        defer module.deinit(allocator);
        @memset(guest.bytes[0x10000..0x10040], 0);
        guest.word(0x10000, 0x1234_5678);
        guest.word(0x10020, initial);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 64);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 512);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var counter: [64]u8 = undefined;
        var values: [512]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &counter);
        try renderer.readbackGuestStorageBuffer(0x11000, &values);
        const expected = if (selected >= 128 or offset == 64) initial else if (opcode == .buffer_atomic_add) initial + 1 else input;
        if (std.mem.readInt(u32, counter[32..36], .little) != expected) std.debug.print("atomic counter: {s} wave32={any} lane={d} offset={d} return={any}\n", .{ @tagName(opcode), wave32, selected, offset, returns });
        try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, counter[0..4], .little));
        try std.testing.expectEqual(expected, std.mem.readInt(u32, counter[32..36], .little));
        for (0..128) |lane| {
            const expected_value = if (lane != selected) poison else if (!returns) input else if (offset == 64) 0 else initial;
            if (std.mem.readInt(u32, values[lane * 4 ..][0..4], .little) != expected_value) std.debug.print("atomic return: {s} wave32={any} selected={d} lane={d} offset={d} return={any}\n", .{ @tagName(opcode), wave32, selected, lane, offset, returns });
            try std.testing.expectEqual(expected_value, std.mem.readInt(u32, values[lane * 4 ..][0..4], .little));
        }
    };
    // All workgroups update the same word. Float min/max must be a single
    // atomic RMW; separate atomic loads and stores can lose another lane's
    // extremum even when every invocation has EXEC enabled.
    for (types) |opcode| {
        const initial: u32 = switch (opcode) {
            .buffer_atomic_add => 0,
            .buffer_atomic_fmin => @bitCast(@as(f32, 10000)),
            .buffer_atomic_fmax => @bitCast(@as(f32, -10000)),
            else => unreachable,
        };
        const atomic = mubuf(switch (opcode) {
            .buffer_atomic_add => 0x32,
            .buffer_atomic_fmin => 0x3f,
            .buffer_atomic_fmax => 0x40,
            else => unreachable,
        }, 0, 1, 0, 4);
        const code = [_]u32{
            if (opcode == .buffer_atomic_add) vop1(1, 1, 129) else vop1(6, 1, 256),
            atomic[0] & ~@as(u32, 1 << 13),
            atomic[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 16);
        defer analysis.deinit(allocator);
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .local_size = .{ 128, 1, 1 },
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{.{ .resource_sgpr = 4, .descriptor_index = 0, .extent_bytes = 4 }},
        });
        defer module.deinit(allocator);
        guest.word(0x10000, initial);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 4);
        _ = try renderer.dispatchSpirv(module.words, .{ 8, 1, 1 });
        var counter: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &counter);
        const expected: u32 = switch (opcode) {
            .buffer_atomic_add => 1024,
            .buffer_atomic_fmin => @bitCast(@as(f32, 0)),
            .buffer_atomic_fmax => @bitCast(@as(f32, 127)),
            else => unreachable,
        };
        try std.testing.expectEqual(expected, std.mem.readInt(u32, &counter, .little));
    }
    std.debug.print("buffer atomics passed: masked poison values, wave32/wave64, high lanes, empty EXEC, OOB, returned values and concurrent integer/float RMW\n", .{});
}

fn runWideMaskProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var case: u32 = 0;
    for ([_]u32{ 64, 512 }) |lanes| for ([_]u8{ 106, 12 }) |sdst| for ([_]u8{ 0, 16, 32, 48, 64 }) |threshold| for (0..3) |encoding| {
        case += 1;
        const code = [_]u32{
            0x3602_00bf, // v1 = v0 & 63
            vop1(1, 2, 128 + @as(u9, threshold)),
            vop1(1, 3, 170), // sentinel 42
            sop1(4, sdst, 193), // stale high mask must be replaced by the comparison
            if (encoding == 1) 0xd4c1_0000 | @as(u32, sdst) else 0x7d82_04f9,
            if (encoding == 1) 257 | (258 << 9) else 0x0606_8001 | (@as(u32, sdst) << 8),
            // The scene classifier compares a saved 64-bit mask into another
            // SGPR pair, then intersects that result with the current EXEC.
            if (encoding == 2) 0xd4e4_001c else 0xbf80_0000,
            if (encoding == 2) @as(u32, sdst) | (128 << 9) else 0xbf80_0000,
            sop1(0x24, 20, if (encoding == 2) 28 else sdst), // save EXEC, enter the true lanes
            vop1(1, 3, 129),
            0x8afe_7e14, // exec = saved & ~exec: the complementary lanes
            vop1(1, 3, 130),
            sop1(4, 126, 20),
            mubuf(0x1c, 0, 3, 0, 0)[0],
            mubuf(0x1c, 0, 3, 0, 0)[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(case * 256 + index * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, case);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, 4 << 1);
        for ([_]u32{ 0x10000, 4 << 16, lanes, 0 }, 0..) |word, index|
            try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ lanes, 1, 1 }, .{ 1, 1, 1 });
        var output: [512 * 4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, output[0 .. lanes * 4]);
        for (0..lanes) |lane| {
            const expected: u32 = if (lane % 64 < threshold) 1 else 2;
            const actual = std.mem.readInt(u32, output[lane * 4 ..][0..4], .little);
            if (actual != expected) std.debug.print("mask case={d} encoding={d} lanes={d} SDST={d} threshold={d} lane={d}\n", .{ case, encoding, lanes, sdst, threshold, lane });
            try std.testing.expectEqual(expected, actual);
        }
    };
    std.debug.print("wide masks passed: SDWA/VOP3/U64 comparisons, VCC/SGPR pairs, saved EXEC, complementary lanes and 64/512 invocations\n", .{});
}

fn runPairedLds64Probe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const expected = [_]u32{ 0x1234_5678, 0xdead_beef, 0x7654_3210, 0x8765_4321 };
    for ([_]bool{ false, true }) |stride64| {
        const scale: u32 = if (stride64) 512 else 8;
        const write_opcode: u32 = if (stride64) 0x4f else 0x4e;
        const read_opcode: u32 = if (stride64) 0x78 else 0x77;
        const code = [_]u32{
            vop1(1, 1, 128),
            vop1(1, 2, 255),
            expected[0],
            vop1(1, 3, 255),
            expected[1],
            vop1(1, 8, 255),
            expected[2],
            vop1(1, 9, 255),
            expected[3],
            // Paired stores must agree with independent single-value loads.
            0xd800_0000 | (write_opcode << 18) | (7 << 8) | 3,
            0x0008_0201,
            0xbf8a_0000,
            0xd800_0000 | (0x76 << 18) | (3 * scale),
            0x0a00_0001,
            0xd800_0000 | (0x76 << 18) | (7 * scale),
            0x0c00_0001,
            mubuf(0x1e, 0, 10, 0, 0)[0],
            mubuf(0x1e, 0, 10, 0, 0)[1],
            vop1(1, 1, 255),
            256,
            // The reverse direction also prevents wrong offsets cancelling out.
            0xd800_0000 | (0x4d << 18) | (3 * scale),
            0x0000_0201,
            0xd800_0000 | (0x4d << 18) | (7 * scale),
            0x0000_0801,
            0xbf8a_0000,
            0xd800_0000 | (read_opcode << 18) | (7 << 8) | 3,
            0x0e00_0001,
            mubuf(0x1e, 16, 14, 0, 0)[0],
            mubuf(0x1e, 16, 14, 0, 0)[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 128);
        defer analysis.deinit(allocator);
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .local_size = .{ 1, 1, 1 },
            .workgroup_memory_size_bytes = 8192,
            .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 32 }},
        });
        defer module.deinit(allocator);
        @memset(guest.bytes[0x10000..0x10020], 0xaa);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 32);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [32]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        for (0..8) |index| {
            const actual = std.mem.readInt(u32, output[index * 4 ..][0..4], .little);
            if (actual != expected[index % 4]) std.debug.print("paired LDS64 stride64={any} word={d}\n", .{ stride64, index });
            try std.testing.expectEqual(expected[index % 4], actual);
        }
    }
    std.debug.print("paired LDS64 passed: independent single/paired reads and writes, all four words, ordinary and stride64 offsets\n", .{});
    // ADDTID also needs lane identity when the shader has no EXEC operations.
    const addtid = [_]u32{
        sop1(3, 124, 144), // M0 = 16.
        0xdac0_0100, 0, // ds_write_addtid_b32 v0 offset:256
        0xbf8a_0000,
        0xdac4_0100,                0x0100_0000, // ds_read_addtid_b32 v1 offset:256
        mubuf(0x1c, 0, 1, 0, 0)[0], mubuf(0x1c, 0, 1, 0, 0)[1],
        0xbf81_0000,
    };
    for (addtid, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 32);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .workgroup_memory_size_bytes = 1024,
        .compute_inputs = .{ .local_invocation_id_components = 1 },
        .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 256, .stride = 4 }},
    });
    defer module.deinit(allocator);
    @memset(guest.bytes[0x10000..0x10100], 0xaa);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 256);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    var output: [256]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x10000, &output);
    for (0..64) |lane| try std.testing.expectEqual(@as(u32, @intCast(lane)), std.mem.readInt(u32, output[lane * 4 ..][0..4], .little));
    std.debug.print("LDS ADDTID passed: 64 independent lanes, M0 base and instruction byte offset without explicit EXEC access\n", .{});
    try runLdsReadAliasProbe(allocator);
}

fn runLdsReadAliasProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const expected = [_]u32{ 0x1234_5678, 0xdead_beef, 0x7654_3210, 0x8765_4321 };
    for ([_]u32{ 0x37, 0x38, 0x76, 0x77, 0x78, 0xfe, 0xff }) |opcode| {
        const paired = opcode == 0x37 or opcode == 0x38 or opcode == 0x77 or opcode == 0x78;
        const wide_pair = opcode == 0x77 or opcode == 0x78;
        const words_per_value: u32 = if (wide_pair) 2 else 1;
        const count: usize = switch (opcode) {
            0x37, 0x38, 0x76 => 2,
            0xfe => 3,
            else => 4,
        };
        const scale: u32 = switch (opcode) {
            0x38 => 256,
            0x78 => 512,
            0x77 => 8,
            else => 4,
        };
        for ([_]u8{ 4, 5 }) |address_register| {
            var code: std.ArrayList(u32) = .empty;
            defer code.deinit(allocator);
            try code.appendSlice(allocator, &.{ vop1(1, 0, 128), vop1(1, address_register, 255), 64 });
            for (0..count) |index| {
                const value_register: u8 = @intCast(10 + index);
                const offset: u32 = if (paired)
                    @as(u32, if (index / words_per_value == 0) 3 else 7) * scale + @as(u32, @intCast(index % words_per_value)) * 4
                else
                    16 + @as(u32, @intCast(index)) * 4;
                try code.appendSlice(allocator, &.{
                    vop1(1, value_register, 255),        expected[index],
                    0xd800_0000 | (0x0d << 18) | offset, (@as(u32, value_register) << 8) | address_register,
                });
            }
            try code.appendSlice(allocator, &.{
                0xbf8a_0000,
                0xd800_0000 | (opcode << 18) | @as(u32, if (paired) (7 << 8) | 3 else 16),
                (4 << 24) | @as(u32, address_register),
            });
            for (0..count) |index| {
                const store = mubuf(0x1c, @intCast(index * 4), @intCast(4 + index), 0, 0);
                try code.appendSlice(allocator, &store);
            }
            try code.append(allocator, 0xbf81_0000);
            for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
            var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 128);
            defer analysis.deinit(allocator);
            var module = try analysis.translateSpirv(allocator, .{
                .stage = .compute,
                .local_size = .{ 1, 1, 1 },
                .workgroup_memory_size_bytes = 8192,
                .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 16 }},
            });
            defer module.deinit(allocator);
            @memset(guest.bytes[0x10000..0x10010], 0xaa);
            _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 16);
            _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
            var output: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x10000, &output);
            for (0..count) |index| {
                const actual = std.mem.readInt(u32, output[index * 4 ..][0..4], .little);
                if (actual != expected[index]) std.debug.print("LDS alias opcode=0x{x} address=v{d} word={d}\n", .{ opcode, address_register, index });
                try std.testing.expectEqual(expected[index], actual);
            }
        }
    }
    std.debug.print("LDS address aliases passed: single and paired B32/B64/B96/B128 reads with first/interior destination overlap\n", .{});
}

fn runLdsWaveMemoryProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const lanes = 64;
    const groups = 64;
    const bytes = lanes * groups * 8;
    for ([_]bool{ false, true }) |explicit_barrier| {
        const load = mubuf(0x0d, 0, 4, 8, 0);
        const store = mubuf(0x1d, 0, 6, 8, 4);
        const code = [_]u32{
            vop1(1, 8, 8),
            (0x1a << 25) | (8 << 17) | (8 << 9) | 134, // Group * 64.
            vop2(0x25, 8, 0, 8),
            (0x1a << 25) | (1 << 17) | 131, // LDS address = lane * 8.
            (0x1d << 25) | (2 << 17) | 160, // Exchange with the other half.
            (0x1a << 25) | (3 << 17) | (2 << 9) | 131,
            load[0],
            load[1],
            0xbf8c_0000,
            0xd934_0000,
            0x0000_0401,
            if (explicit_barrier) 0xbf8a_0000 else 0xbf8c_0000,
            0xd9d8_0000,
            0x0600_0003,
            store[0],
            store[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 64);
        defer analysis.deinit(allocator);
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .local_size = .{ lanes, 1, 1 },
            // Wave32 requires its explicit cross-wave barrier; wave64 orders
            // these accesses within one guest wave without S_BARRIER.
            .wave32 = explicit_barrier,
            .compute_inputs = .{ .local_invocation_id_components = 1, .workgroup_id_sgprs = .{ 8, null, null } },
            .workgroup_memory_size_bytes = 512,
            .storage_buffers = &.{
                .{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = bytes, .stride = 8 },
                .{ .resource_sgpr = 4, .descriptor_index = 1, .extent_bytes = bytes, .stride = 8 },
            },
        });
        defer module.deinit(allocator);
        for (0..8) |iteration| {
            for (0..lanes * groups * 2) |index| guest.word(0x10000 + index * 4, @intCast(1 + index + iteration * 100000));
            @memset(guest.bytes[0x18000..0x20000], 0xaa);
            _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, bytes);
            _ = try renderer.stageGuestStorageBufferAt(1, 0x18000, bytes);
            _ = try renderer.dispatchSpirv(module.words, .{ groups, 1, 1 });
            var output: [bytes]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x18000, &output);
            for (0..lanes * groups) |index| {
                for (0..2) |word| {
                    const expected: u32 = @intCast(1 + (index ^ 32) * 2 + word + iteration * 100000);
                    const actual = std.mem.readInt(u32, output[index * 8 + word * 4 ..][0..4], .little);
                    if (actual != expected) std.debug.print("LDS wave memory barrier={} iteration={d} lane={d} word={d}\n", .{ explicit_barrier, iteration, index, word });
                    try std.testing.expectEqual(expected, actual);
                }
            }
        }
    }
    std.debug.print("LDS wave memory passed: 64 workgroups, cross-half B64 exchange after buffer loads, changed inputs and explicit wave32 barrier\n", .{});
}

fn runSpilledLdsProbe(allocator: std.mem.Allocator) !void {
    try runSpilledLdsWaveProbe(allocator, true);
    try runSpilledLdsWaveProbe(allocator, false);
}

fn runSpilledLdsWaveProbe(allocator: std.mem.Allocator, wave32: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    const Memory = SizedGuestMemory(1024 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 8, 10), vop2Source(0x1a, 8, 129, 8), vop2Source(0x25, 8, 9, 8),
        vop2Source(0x1a, 8, 129, 8), vop2Source(0x25, 8, 8, 8), // ((z * 2 + y) * 2 + x)
        vop2Source(0x1a, 8, 134, 8), vop2Source(0x25, 8, 256, 8),
        vop2Source(0x1a, 1, 131, 0), vop2Source(0x25, 1, 255, 1),
        0xfe00,                      vop2Source(0x1d, 2, 160, 0),
        vop2Source(0x1a, 3, 131, 2), vop2Source(0x25, 3, 255, 3),
        0xfe00,                      mubuf(0x0d, 0, 4, 8, 0)[0],
        mubuf(0x0d, 0, 4, 8, 0)[1],  0xd934_0000,
        0x0000_0401,                 0xbf8a_0000,
        0xd9d8_0000,                 0x0600_0003,
        mubuf(0x1d, 0, 6, 8, 4)[0],  mubuf(0x1d, 0, 6, 8, 4)[1],
        vop1(1, 4, 255),             0x80000000,
        0xdc34_0000,                 0x0a00_0003, // same LDS bytes through FLAT
        mubuf(0x1d, 8, 10, 8, 4)[0], mubuf(0x1d, 8, 10, 8, 4)[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = guest, .read_fn = Memory.read }, 0x100, code.len);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .wave32 = wave32,
        .wave64_workgroup = !wave32,
        .compute_inputs = .{ .local_invocation_id_components = 1, .workgroup_id_sgprs = .{ 8, 9, 10 } },
        .workgroup_memory_size_bytes = 65536,
        .workgroup_memory_storage_slot = 2,
        .flat_apertures = .{ .shared = 0x80000000 },
        .flat_memories = &.{.{ .descriptor_index = 3, .fault_record_word = 8 }},
        .storage_buffers = &.{ .{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 8 }, .{ .resource_sgpr = 4, .descriptor_index = 1, .stride = 16 } },
    });
    defer module.deinit(allocator);
    for (0..2) |iteration| {
        for (0..512 * 2) |index| guest.word(0x10000 + index * 4, @intCast(1 + index + iteration * 100000));
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 512 * 8);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x18000, 512 * 16);
        _ = try renderer.stageGuestStorageBufferAt(2, 0x20000, 8 * 65536);
        _ = try renderer.stageGuestStorageBufferAt(3, 0xa0000, 48);
        _ = try renderer.dispatchSpirv(module.words, .{ 2, 2, 2 });
        var output: [512 * 16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x18000, &output);
        for (0..512) |lane| for (0..4) |word| {
            const expected: u32 = @intCast(1 + (lane ^ 32) * 2 + word % 2 + iteration * 100000);
            const actual = std.mem.readInt(u32, output[lane * 16 + word * 4 ..][0..4], .little);
            if (actual != expected) std.debug.print("Spilled LDS iteration={d} lane={d} word={d} expected={x} actual={x}\n", .{ iteration, lane, word, expected, actual });
            try std.testing.expectEqual(expected, actual);
        };
        var fault: [48]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0xa0000, &fault);
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, fault[8..12], .little));
    }
    std.debug.print("Spilled LDS passed (wave32={any}): 64 KiB per group, 2x2x2 isolation, cross-half DS/FLAT exchange, barriers and refreshed inputs\n", .{wave32});
}

fn runDispatcherBudgetProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const store = mubuf(0x1c, 0, 0, 1, 4);
    const code = [_]u32{
        sop1(3, 0, 128), vop1(1, 1, 128), // Counter and output offset.
        0xbf0a_ff00, 512, // s_cmp_lt_u32 s0, 512
        0xbf84_0008, // Exit at pc 52.
        0x8000_8100, // s_add_u32 s0, s0, 1
        0xbf06_8100, // s_cmp_eq_u32 s0, 1
        0xbf84_0001, // Inner selection forces dispatcher lowering.
        0xbf80_0000,
        vop1(1, 0, 0),
        store[0],
        store[1],
        0xbf82_fff5, // Back to pc 8.
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 64);
    defer analysis.deinit(allocator);
    for ([_][2]u32{ .{ 8, 2 }, .{ 2048, 512 }, .{ 8, 2 } }) |test_case| {
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .maximum_dispatcher_iterations = test_case[0],
            .report_dispatcher_exhaustion = true,
            .storage_buffers = &.{.{ .resource_sgpr = 4, .descriptor_index = 0, .extent_bytes = 4 }},
            .flat_memories = &.{.{ .descriptor_index = 1, .fault_record_word = 8 }},
        });
        defer module.deinit(allocator);
        try std.testing.expect(module.used_dispatcher);
        guest.word(0x10000, 0);
        guest.word(0x12008, 0);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 4);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x12000, 48);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        try std.testing.expectEqual(test_case[1], std.mem.readInt(u32, &output, .little));
        var fault: [48]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x12000, &fault);
        try std.testing.expectEqual(@as(u32, if (test_case[0] == 8) 1 else 0), std.mem.readInt(u32, fault[8..12], .little));
        if (test_case[0] == 8) {
            try std.testing.expectEqual(@as(u32, 0xffffffff), std.mem.readInt(u32, fault[32..36], .little));
            try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, fault[40..44], .little));
        }
    }
    std.debug.print("dispatcher budgets passed: bounded early exit, 512 complete iterations and pipeline reuse\n", .{});
}

fn runWave64BallotsProbe(allocator: std.mem.Allocator) !void {
    inline for (.{ 64, 128, 512 }) |lanes| for ([_]bool{ false, true }) |double_buffer| {
        try runWave64BallotsCase(allocator, double_buffer, lanes);
    };
}

fn runWave64BallotsCase(allocator: std.mem.Allocator, double_buffer: bool, comptime lanes: usize) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    const groups = 64;
    const output_bytes = groups * lanes * 4;
    const Memory = SizedGuestMemory(output_bytes + 0x10000);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    _ = renderer.dcbBackend(guest.interface());
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    try code.appendSlice(allocator, &.{
        vop1(1, 7, 8),   vop2Source(0x1a, 7, 128 + @as(u9, std.math.log2_int(usize, lanes)), 7), vop2(0x25, 7, 0, 7),
        vop1(1, 1, 8),   vop2Source(0x1b, 1, 191, 1),                                            vop2(0x1d, 1, 0, 1),
        vop1(1, 2, 128), vop1(1, 4, 135),
    });
    for (0..32) |round| {
        const cutoff: u32 = @intCast((round * 7 + 5) % 65);
        try code.appendSlice(allocator, &.{
            0x7d88_0200 | (128 + cutoff),
            vop2Source(1, 3, 129, 4), // Lane-local VCC selection: false=1, true=7.
            vop2(0x25, 2, 3, 2),
            0x7d88_0200 | (128 + cutoff), // CMP_GT cutoff, v1; full VCC pair.
            vop2Source(0x25, 2, 106, 2),
            vop2Source(0x1d, 2, 107, 2),
            vop1(2, 10, 257), // Interleave a full mask with two cross-half exchanges.
            0xd760_000b,                257 | (191 << 9), // READLANE s11, v1, 63.
            vop2Source(0x25, 2, 10, 2), vop2Source(0x1d, 2, 11, 2),
        });
    }
    try code.appendSlice(allocator, &mubuf(0x1c, 0, 2, 7, 0));
    try code.append(allocator, 0xbf81_0000);
    for (code.items, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = guest, .read_fn = Memory.read }, 0x100, code.items.len);
    defer analysis.deinit(allocator);
    var baseline = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .wave64_workgroup = true,
        .wave_exchange_double_buffer = double_buffer,
        .local_size = .{ lanes, 1, 1 },
        .compute_inputs = .{ .local_invocation_id_components = 1, .workgroup_id_sgprs = .{ 8, null, null } },
        .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = output_bytes, .stride = 4 }},
    });
    defer baseline.deinit(allocator);
    const expected = try allocator.alloc(u32, groups * lanes);
    defer allocator.free(expected);
    @memset(expected, 0);
    for (expected, 0..) |*value, invocation| for (0..32) |round| {
        const group = invocation / lanes;
        const local_lane = invocation % lanes;
        const wave_base = local_lane & ~@as(usize, 63);
        const cutoff = (round * 7 + 5) % 65;
        var mask: u64 = 0;
        for (0..64) |lane| {
            if ((wave_base + lane) ^ (group & 63) < cutoff) mask |= @as(u64, 1) << @intCast(lane);
        }
        const selected: u32 = if (local_lane ^ (group & 63) < cutoff) 7 else 1;
        value.* = (value.* +% selected +% @as(u32, @truncate(mask))) ^ @as(u32, @truncate(mask >> 32));
        value.* = (value.* +% @as(u32, @intCast(wave_base ^ (group & 63)))) ^ @as(u32, @intCast((wave_base + 63) ^ (group & 63)));
    };
    const output = try allocator.alloc(u8, output_bytes);
    defer allocator.free(output);
    @memset(guest.bytes[0x10000..], 0xa5);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, output_bytes);
    _ = try renderer.dispatchSpirv(baseline.words, .{ groups, 1, 1 });
    try renderer.readbackGuestStorageBuffer(0x10000, output);
    for (0..groups * lanes) |lane| {
        const actual = std.mem.readInt(u32, output[lane * 4 ..][0..4], .little);
        try std.testing.expectEqual(expected[lane], actual);
    }
    std.debug.print("explicit wave64 ballots passed: lanes={d} double_buffer={} 32 interleaved masks and cross-half exchanges across 64 groups\n", .{ lanes, double_buffer });
}

fn runWave64Probe(allocator: std.mem.Allocator) !void {
    for ([_][3]u32{ .{ 64, 1, 1 }, .{ 4, 4, 4 } }) |local_size| try runWave64Case(allocator, local_size);
    std.debug.print("wave64 passed: lane 63, full masks, carry bits and uniform EXEC branches across workgroup shapes\n", .{});
}

fn runMultiWave64Probe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 1, 256), // Retain the workgroup-local index.
        0xd760_0008,   257 | (191 << 9), // READLANE s8, v1, 63.
        vop1(1, 2, 8), 0xe070_2000,
        0x8000_0201,   0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 32);
    defer analysis.deinit(allocator);
    for ([_]u32{ 64, 128, 256 }) |lanes| {
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .local_size = .{ lanes, 1, 1 },
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = lanes * 4, .stride = 4 }},
        });
        defer module.deinit(allocator);
        @memset(guest.bytes[0x10000..][0 .. lanes * 4], 0xa5);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, lanes * 4);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [1024]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, output[0 .. lanes * 4]);
        for (0..lanes) |lane| {
            const expected: u32 = @intCast((lane / 64) * 64 + 63);
            const actual = std.mem.readInt(u32, output[lane * 4 ..][0..4], .little);
            if (actual != expected) std.debug.print("multi-wave64 lanes={d} lane={d}: expected={d} actual={d}\n", .{ lanes, lane, expected, actual });
            try std.testing.expectEqual(expected, actual);
        }
    }
    for ([_][3]u32{ .{ 128, 1, 1 }, .{ 16, 16, 1 } }) |shape| try runMultiWave64DivergenceCase(allocator, shape);
    std.debug.print("multi-wave64 passed: cross-half reads, independent loops, LDS rendezvous, partial EXEC and early wave termination\n", .{});
}

fn runMultiWave64DivergenceCase(allocator: std.mem.Allocator, shape: [3]u32) !void {
    const lanes = shape[0] * shape[1];
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    try code.appendSlice(allocator, &.{
        0xd746_0007, 257 | (132 << 9) | (256 << 18), // v7 = local y * 16 + x.
        (0x16 << 25) | (3 << 17) | (7 << 9) | 134, // v3 = wave index.
        0xd760_0009, 259 | (128 << 9), // READLANE s9, v3, 0.
        0x800a_8109, // s10 = wave index + 1.
        sop1(3, 11, 128),
    });
    const loop = code.items.len;
    try code.appendSlice(allocator, &.{
        0x800b_810b, // Each wave takes a different number of iterations.
        0xd760_000c, 263 | (191 << 9), // READLANE inside the divergent loop.
        0xbf0a_0a0b, // s_cmp_lt_u32 s11, s10.
    });
    const back: i16 = @intCast(@as(i64, @intCast(loop)) - @as(i64, @intCast(code.items.len)) - 1);
    try code.append(allocator, 0xbf85_0000 | @as(u32, @as(u16, @bitCast(back))));
    try code.appendSlice(allocator, &.{
        vop1(1, 4, 11),
        (0x1a << 25) | (5 << 17) | (7 << 9) | 130,
        0xd834_0000, 0x0000_0405, // LDS[local index] = loop count.
        0xbf8a_0000,
        (0x25 << 25) | (6 << 17) | (7 << 9) | 192, // Other wave's index.
        (0x1b << 25) | (6 << 17) | (6 << 9) | 255,
        lanes - 1,
        (0x1a << 25) | (6 << 17) | (6 << 9) | 130,
        0xd8d8_0000, 0x0400_0006, // LDS read after all waves arrive.
        0xbf8c_0000,
    });
    try code.appendSlice(allocator, &mubuf(0x1c, 0, 4, 7, 0));
    try code.append(allocator, vop1(1, 2, 12));
    try code.appendSlice(allocator, &mubuf(0x1c, 4, 2, 7, 0));
    try code.append(allocator, 0xbf06_8009); // Only wave zero continues.
    const early_end = code.items.len;
    try code.append(allocator, 0);
    try code.appendSlice(allocator, &.{
        0x7da6_0ea3, // CMPX: guest lanes 35..63.
        0xbf88_0003, // EXECZ must keep the full guest wave together.
        vop1(2, 10, 263), // READFIRSTLANE gives 35 despite native subgroup32.
        0xd760_000c,
        263 | (191 << 9),
        sop1(4, 126, 193), // Restore EXEC before writing all lanes.
        vop1(1, 2, 12),
        vop1(1, 3, 10),
    });
    try code.appendSlice(allocator, &mubuf(0x1c, 8, 2, 7, 0));
    try code.appendSlice(allocator, &mubuf(0x1c, 12, 3, 7, 0));
    code.items[early_end] = 0xbf84_0000 | @as(u32, @intCast(code.items.len - early_end - 1));
    try code.append(allocator, 0xbf81_0000);
    for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 128);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = shape,
        .compute_inputs = .{ .local_invocation_id_components = 2 },
        .workgroup_memory_size_bytes = lanes * 4,
        .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = lanes * 16, .stride = 16 }},
    });
    defer module.deinit(allocator);
    try std.testing.expect(module.used_dispatcher);
    @memset(guest.bytes[0x10000..][0 .. lanes * 16], 0xa5);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, lanes * 16);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    var output: [4096]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x10000, output[0 .. lanes * 16]);
    for (0..lanes) |lane| {
        const expected = [_]u32{
            @intCast(((lane + 64) % lanes) / 64 + 1),
            @intCast((lane / 64) * 64 + 63),
            if (lane < 64) 63 else 0xa5a5_a5a5,
            if (lane < 64) 35 else 0xa5a5_a5a5,
        };
        for (expected, 0..) |value, component| {
            const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
            if (value != actual) std.debug.print("wave64 divergence shape={any} lane={d} component={d}: expected={d} actual={d}\n", .{ shape, lane, component, value, actual });
            try std.testing.expectEqual(value, actual);
        }
    }
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

fn runDeferredShaderMetadataProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |deferred| {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .defer_small_storage_writes = deferred });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        // One GPU dispatch generates a V# inside a small output buffer. The
        // following dispatch loads it with SMEM before using the resource.
        const producer = [_]u32{
            vop1(1, 0, 4), vop1(1, 1, 5), vop1(1, 2, 6), vop1(1, 3, 7),
            0xe0780010,    0x80000000,    0xbf810000,
        };
        const consumer = [_]u32{
            0xf4080200, (125 << 25) | 16, // s8:s11 = generated descriptor at root+16
            0xe0300000, 0x80020000, // load through V#s8
            0xe0700000, 0x80010000, // store through V#s4
            0xbf810000,
        };
        for (producer, 0..) |word, i| guest.word(0x100 + i * 4, word);
        for (consumer, 0..) |word, i| guest.word(0x200 + i * 4, word);
        guest.word(0x6000, 0x12345678);
        var state = gpu.State{};
        const stage = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, stage.programRegisterBase(), 1);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 8 << 1);
        for ([_]u32{ 0x1000, 0, 32, 0, 0x6000, 0, 4, 0 }, 0..) |word, i|
            try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try std.testing.expectEqual(@as(u32, if (deferred) 0 else 0x6000), std.mem.readInt(u32, guest.bytes[0x1010..][0..4], .little));
        try state.writeRegister(.shader, stage.programRegisterBase(), 2);
        for ([_]u32{ 0x1000, 0, 0, 0, 0x3000, 0, 4, 0 }, 0..) |word, i|
            try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var output: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x3000, &output);
        const actual = std.mem.readInt(u32, &output, .little);
        if (actual != 0x12345678) {
            std.debug.print("GPU-generated shader metadata mismatch deferred={any}: expected=0x12345678 actual=0x{x}\n", .{ deferred, actual });
            return error.DeferredShaderMetadataMismatch;
        }
        // Generate a different descriptor before a graphics draw. Reading
        // the previous CPU copy would bind the black source instead of red.
        guest.word(0x6000, 0);
        guest.word(0x6100, 0x3f800000);
        try state.writeRegister(.shader, stage.programRegisterBase(), 1);
        for ([_]u32{ 0x1000, 0, 32, 0, 0x6100, 0, 4, 0 }, 0..) |word, i|
            try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        const vertex = [_]u32{
            0x34020a81,      0x36040a82, 0x36020282, 0x7e040d02, 0x7e060d01,
            0xd5410001,      0x03ce04f4, 0xd5410002, 0x03ce06f4, vop1(1, 0, 242),
            vop1(1, 3, 240), 0xf80008cf, 0x00030102, 0xbf810000,
        };
        const fragment = [_]u32{
            0xf4080200,      (125 << 25) | 16, 0xe0300000, 0x80020000,
            vop1(1, 1, 128), vop1(1, 2, 242),  0xf800180f, 0x02010100,
            0xbf810000,
        };
        for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |graphics_stage, program| {
            try state.writeRegister(.shader, graphics_stage.programRegisterBase(), program);
            try state.writeRegister(.shader, graphics_stage.programRegisterBase() + 1, 0);
        }
        try state.writeRegister(.shader, 0xb, 2 << 1);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase(), 0x1000);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase() + 1, 0);
        const context = [_][2]u32{
            .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
            .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
            .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
            .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        for ([_]f32{ 4, 4, -4, 4, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (0..64) |pixel| try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.readInt(u32, guest.bytes[0x2000 + pixel * 4 ..][0..4], .little));
    }
    std.debug.print("GPU-generated shader metadata passed: interior descriptor reads before dependent compute and graphics, eager and deferred writes\n", .{});
}

fn runDeferredReleaseProbe(allocator: std.mem.Allocator) !void {
    const Audit = struct {
        guest: SizedGuestMemory(512 * 1024) = .{},
        expected: u32 = 0,
        label_observed_correct_data: bool = false,
        reject_second_output: bool = false,
        fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return SizedGuestMemory(512 * 1024).read(&self.guest, address, destination);
        }
        fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address == 0x2000 and self.reject_second_output) return false;
            if (address == 0x8000) {
                self.label_observed_correct_data = true;
                for (0..3) |i| {
                    const at = 0x1000 + i * 0x1000;
                    self.label_observed_correct_data = self.label_observed_correct_data and
                        std.mem.readInt(u32, self.guest.bytes[at..][0..4], .little) == self.expected + i;
                }
            }
            return SizedGuestMemory(512 * 1024).write(&self.guest, address, bytes);
        }
    };
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .defer_small_storage_writes = true });
    defer renderer.deinit();
    var audit = Audit{};
    const backend = renderer.dcbBackend(.{ .context = &audit, .read = Audit.read, .write = Audit.write });
    const code = [_]u32{ vop1(1, 0, 4), 0xe0700000, 0x80000000, 0xbf810000 };
    for (code, 0..) |word, i| audit.guest.word(0x100 + i * 4, word);
    const compute = gpu.resources.ShaderStage.compute;
    var state = gpu.State{};
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 5 << 1);
    for (0..4) |round| {
        audit.expected = @intCast(100 * (round + 1));
        audit.label_observed_correct_data = false;
        for (0..4) |i| {
            const address: u32 = if (i < 3) @intCast(0x1000 + i * 0x1000) else 0x10000;
            const size: u32 = if (i < 3) 4 else 256 * 1024;
            const words = [_]u32{ address, 4 << 16, size / 4, 0, audit.expected + @as(u32, @intCast(i)) };
            for (words, 0..) |word, j|
                try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(j)), word);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            const before: u32 = if (i < 3 and round != 0) @intCast(100 * round + i) else 0;
            try std.testing.expectEqual(before, std.mem.readInt(u32, audit.guest.bytes[address..][0..4], .little));
        }
        const release = gpu.state.ReleaseMem{
            .event_type = 40,
            .event_index = 5,
            .gcr_control = 0x200,
            .cache_policy = 0,
            .destination = 1,
            .interrupt = 2,
            .data_selection = 2,
            .address = 0x8000,
            .data = round + 1,
            .interrupt_context_id = 0,
            .standard_packet = true,
        };
        if (round == 2) {
            // A cache event without a payload keeps the work resident; an
            // addressed event is a host-visible completion boundary.
            try std.testing.expect(backend.vtable.event.?(backend.context, .{
                .event_type = 7,
                .event_index = 4,
                .address = null,
            }));
            try std.testing.expectEqual(@as(u32, 200), std.mem.readInt(u32, audit.guest.bytes[0x1000..][0..4], .little));
            try std.testing.expect(backend.vtable.event.?(backend.context, .{
                .event_type = 0x38,
                .event_index = 4,
                .address = 0x8000,
            }));
            for (0..3) |i| {
                const at = 0x1000 + i * 0x1000;
                try std.testing.expectEqual(audit.expected + @as(u32, @intCast(i)), std.mem.readInt(u32, audit.guest.bytes[at..][0..4], .little));
            }
        }
        if (round == 3) {
            // A failed output write must not expose the completion label.
            audit.reject_second_output = true;
            try std.testing.expect(!backend.vtable.release.?(backend.context, release));
            try std.testing.expect(!audit.label_observed_correct_data);
            try std.testing.expectEqual(@as(u64, round), std.mem.readInt(u64, audit.guest.bytes[0x8000..][0..8], .little));
            audit.reject_second_output = false;
        }
        try std.testing.expect(backend.vtable.release.?(backend.context, release));
        try std.testing.expect(audit.label_observed_correct_data);
        try std.testing.expectEqual(@as(u64, round + 1), std.mem.readInt(u64, audit.guest.bytes[0x8000..][0..8], .little));
        // Large outputs retain their existing explicit-readback policy.
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, audit.guest.bytes[0x10000..][0..4], .little));
    }
    std.debug.print("Deferred releases passed: small writes precede completion labels, addressed events publish outputs, failed writes withhold completion, large outputs stay resident\n", .{});
}

fn runImageResinfoProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const stage = gpu.resources.ShaderStage.compute;
    var state = gpu.State{};
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 13 << 1);
    for ([_]u32{ 0x10000, 16 << 16, 1, 0 }, 0..) |word, i|
        try state.writeRegister(.shader, stage.userDataBase() + 8 + @as(u32, @intCast(i)), word);
    // No sampler is supplied. Each query must bind the T# at its own PC,
    // including new extents on a previously translated program.
    for ([_]u32{ 9, 10, 13 }, 0..) |image_type, case| {
        const dimension: u32 = if (image_type == 9) 1 else if (image_type == 10) 2 else 5;
        const code = [_]u32{
            vop1(1, 0, 12), 0xf0380f00 | (dimension << 3), 0x00000400,
            0xe0780000,     0x80020400,                    0xbf810000,
        };
        const program: u32 = 0x100 + @as(u32, @intCast(case)) * 0x100;
        for (code, 0..) |word, i| guest.word(program + i * 4, word);
        try state.writeRegister(.shader, stage.programRegisterBase(), program >> 8);
        for ([_]u32{ 32, 16, 32 }) |width| for (0..2) |base_mip| {
            var descriptor = sampledImageDescriptorWords(0x4000, width, 8);
            descriptor[3] = (descriptor[3] & 0x0fffffff) | (image_type << 28) | (2 << 16) | (@as(u32, @intCast(base_mip)) << 12);
            descriptor[4] = if (image_type == 9) width - 1 else 3;
            descriptor[5] = 2 << 4;
            for (descriptor, 0..) |word, i|
                try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
            for (0..3 - base_mip) |mip| {
                try state.writeRegister(.shader, stage.userDataBase() + 12, @intCast(mip));
                _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
                var bytes: [16]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(0x10000, &bytes);
                const level = mip + base_mip;
                const expected = [_]u32{ width >> @intCast(level), @as(u32, 8) >> @intCast(level), if (image_type == 9) 1 else if (image_type == 10) @as(u32, 4) >> @intCast(level) else 4, @intCast(3 - base_mip) };
                for (expected, 0..) |value, i|
                    try std.testing.expectEqual(value, std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
            }
        };
    }
    try std.testing.expectEqual(@as(u64, 0), renderer.sampled_image_uploads);
    std.debug.print("Image resource queries passed: 2D/3D/array mip extents, no sampler and cached descriptor changes\n", .{});
}

fn runImageD16Probe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const stage = gpu.resources.ShaderStage.compute;
    var state = gpu.State{};
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    var image = sampledImageDescriptorWords(0x8000, 1, 1);
    image[1] = (image[1] & ~(@as(u32, 0x1ff) << 20)) | (77 << 20); // RGBA32_FLOAT
    for (image, 0..) |word, i| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
    for (0..4) |i| try state.writeRegister(.shader, stage.userDataBase() + 8 + @as(u32, @intCast(i)), 0);
    for ([_]u32{ 0x10000, 16 << 16, 1, 0 }, 0..) |word, i|
        try state.writeRegister(.shader, stage.userDataBase() + 12 + @as(u32, @intCast(i)), word);
    for ([_][4]f32{
        .{ 0.375, -0.25, 2, 0.5 },
        .{ 1, 0.125, -4, 0.25 },
        .{ -0.5, 2, 0.25, 1 },
        .{ -0.5, -0.75, 0.25, 1 },
        .{ -0.5, -0.75, 0.25, 1 },
    }, 0..) |texel, input_index| {
        var case_index: u32 = 0;
        // Reuse the IMAGE_LOAD allocation after a full write, a partial write,
        // and no write. All consumers keep the same T# and compiled programs.
        const address: u32 = 0x8000 + @as(u32, @intCast(@min(input_index, 1))) * 0x1000;
        try state.writeRegister(.shader, stage.userDataBase(), address >> 8);
        const input: [4]u32 = @bitCast(texel);
        if (input_index == 3) {
            try std.testing.expect(backend.vtable.write(backend.context, address + 4, std.mem.asBytes(&input)[4..8]));
        } else if (input_index != 4) {
            try std.testing.expect(backend.vtable.write(backend.context, address, std.mem.asBytes(&input)));
        }
        const uploads_before = renderer.sampled_image_uploads;
        for (0..3) |operation| for ([_]u4{ 1, 3, 5, 7, 15 }) |mask| for ([_]bool{ false, true }) |d16| {
            if (operation == 2 and mask != 1) continue; // gather selects one channel
            const program = 0x100 + case_index * 0x100;
            case_index += 1;
            const opcode: u32 = switch (operation) {
                0 => 0xf09c_0008,
                1 => 0xf000_0008,
                else => 0xf11c_0008,
            };
            var code: std.ArrayList(u32) = .empty;
            defer code.deinit(allocator);
            try code.appendSlice(allocator, &.{ vop1(1, 0, 128), vop1(1, 1, 128) });
            for (4..8) |reg| try code.appendSlice(allocator, &.{ vop1(1, @intCast(reg), 255), 0xdead_beef });
            try code.appendSlice(allocator, &.{ opcode | (@as(u32, mask) << 8), 0x0040_0400 | (@as(u32, @intFromBool(d16)) << 31), 0xe078_0000, 0x8003_0400, 0xbf81_0000 });
            for (code.items, 0..) |word, i| guest.word(program + i * 4, word);
            try state.writeRegister(.shader, stage.programRegisterBase(), program >> 8);
            const result = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            try std.testing.expect(result.spirv_words != 0);
            var actual: [4]u32 = undefined;
            try renderer.readbackGuestStorageBuffer(0x10000, std.mem.asBytes(&actual));
            var expected: [4]u32 = @splat(0xdead_beef);
            var index: usize = 0;
            for (0..4) |component| {
                if (operation != 2 and mask & (@as(u4, 1) << @intCast(component)) == 0) continue;
                const value = texel[if (operation == 2) 0 else component];
                if (d16) {
                    const half: u32 = @as(u16, @bitCast(@as(f16, @floatCast(value))));
                    if (index % 2 == 0) expected[index / 2] = half else expected[index / 2] |= half << 16;
                } else expected[index] = @bitCast(value);
                index += 1;
            }
            std.debug.print("MIMG result case {d}: operation={d} mask={x} d16={} actual={any}\n", .{ case_index, operation, mask, d16, actual });
            try std.testing.expectEqualSlices(u32, &expected, &actual);
        };
        if (input_index == 4) try std.testing.expectEqual(uploads_before, renderer.sampled_image_uploads);
    }
    // Store half components into 32-bit images, including sign extension of
    // integer data, then inspect the full-width image readback.
    for ([_]u32{ 77, 75, 76 }, 0..) |format, format_index| {
        const address: u32 = 0xa000 + @as(u32, @intCast(format_index)) * 0x1000;
        image[0] = address >> 8;
        image[1] = (image[1] & ~(@as(u32, 0x1ff) << 20)) | (format << 20);
        for (image, 0..) |word, i| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
        const inputs: [2]u32 = if (format == 77) .{ 0xb400_3600, 0x3800_4000 } else .{ 0xff01_0123, 0x8000_7fff };
        const code = [_]u32{
            vop1(1, 0, 128), vop1(1, 1, 128),
            vop1(1, 4, 255), inputs[0],
            vop1(1, 5, 255), inputs[1],
            0xf020_0f08, 0x8000_0400, // image_store D16, four components from v4:v5
            0xbf81_0000,
        };
        for (code, 0..) |word, i| guest.word(0x7000 + i * 4, word);
        try state.writeRegister(.shader, stage.programRegisterBase(), 0x70);
        const result = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try std.testing.expect(result.spirv_words != 0);
        try renderer.flushPendingGuestWrites();
        const expected: [4]u32 = switch (format) {
            77 => @bitCast([4]f32{ 0.375, -0.25, 2, 0.5 }),
            75 => .{ 0x123, 0xff01, 0x7fff, 0x8000 },
            else => .{ 0x123, 0xffff_ff01, 0x7fff, 0xffff_8000 },
        };
        var actual: [4]u32 = undefined;
        @memcpy(std.mem.asBytes(&actual), guest.bytes[address..][0..16]);
        std.debug.print("MIMG D16 store format={d}: actual={any}\n", .{ format, actual });
        try std.testing.expectEqualSlices(u32, &expected, &actual);
    }
    std.debug.print("MIMG D16 passed: sample/load/gather/store, float and integer data, sparse masks, register guards, changed descriptors and guest writes\n", .{});
}

fn runPackedFloatProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var state = gpu.State{};
    const stage = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 7 << 1);
    for ([_]u32{ 0x10000, 4 << 16, 1, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
    const half = struct {
        fn pair(low: f32, high: f32) u32 {
            return @as(u16, @bitCast(@as(f16, @floatCast(low)))) |
                (@as(u32, @as(u16, @bitCast(@as(f16, @floatCast(high))))) << 16);
        }
    }.pair;
    const Case = struct { opcode: u32 = 0x20, sel: u32 = 0, hi: u32 = 0, neg: u32 = 0, abs_or_hi_neg: u32 = 0, inline_one: bool = false, inputs: [3]u32, expected: u32 };
    const mixed = [3]u32{ @bitCast(@as(f32, 2)), half(3, -4), @bitCast(@as(f32, 0.5)) };
    const packed_inputs = [3]u32{ half(1.5, -2), half(0.5, 4), half(-1, 2) };
    const cases = [_]Case{
        .{ .hi = 2, .inputs = mixed, .expected = @bitCast(@as(f32, 6.5)) },
        .{ .sel = 3, .hi = 2, .inputs = mixed, .expected = @bitCast(@as(f32, -7.5)) }, // FP32 ignores OP_SEL
        .{ .sel = 2, .hi = 2, .abs_or_hi_neg = 2, .inputs = mixed, .expected = @bitCast(@as(f32, 8.5)) },
        .{ .sel = 2, .hi = 2, .neg = 2, .abs_or_hi_neg = 2, .inputs = mixed, .expected = @bitCast(@as(f32, -7.5)) },
        .{ .opcode = 0x21, .hi = 2, .inputs = mixed, .expected = 0x3555_0000 | (half(6.5, 0) & 0xffff) },
        .{ .opcode = 0x22, .sel = 2, .hi = 2, .inputs = mixed, .expected = 0xb800 | (half(0, -7.5) & 0xffff_0000) },
        .{ .opcode = 0x0f, .sel = 3, .hi = 5, .neg = 1, .abs_or_hi_neg = 2, .inputs = packed_inputs, .expected = half(6, -2.5) },
        .{ .opcode = 0x10, .sel = 3, .hi = 5, .neg = 1, .abs_or_hi_neg = 2, .inputs = packed_inputs, .expected = half(8, 1) },
        .{ .opcode = 0x0e, .sel = 3, .hi = 5, .neg = 1, .abs_or_hi_neg = 2, .inputs = packed_inputs, .expected = half(7, 3) },
        .{ .opcode = 0x11, .sel = 3, .hi = 5, .neg = 1, .abs_or_hi_neg = 2, .inputs = packed_inputs, .expected = half(2, -2) },
        .{ .opcode = 0x12, .sel = 3, .hi = 5, .neg = 1, .abs_or_hi_neg = 2, .inputs = packed_inputs, .expected = half(4, -0.5) },
        .{ .opcode = 0x0f, .hi = 2, .inline_one = true, .inputs = packed_inputs, .expected = half(1.5, 5) },
        .{ .opcode = 0x0f, .hi = 3, .inline_one = true, .inputs = packed_inputs, .expected = half(1.5, 4) }, // inline high half is zero
    };
    for (cases, 0..) |case, index| {
        const program: u32 = 0x100 + @as(u32, @intCast(index)) * 0x100;
        const code = [_]u32{
            vop1(1, 0, 255),                                                                                          0x3555_b800,
            0xcc00_0000 | (case.opcode << 16) | (case.sel << 11) | ((case.hi & 4) << 12) | (case.abs_or_hi_neg << 8), @as(u32, if (case.inline_one) 242 else 4) | (5 << 9) | (6 << 18) | ((case.hi & 3) << 27) | (case.neg << 29),
            0xe070_0000,                                                                                              0x8000_0000,
            0xbf81_0000,
        };
        for (code, 0..) |word, i| guest.word(program + i * 4, word);
        for (case.inputs, 0..) |word, i| try state.writeRegister(.shader, stage.userDataBase() + 4 + @as(u32, @intCast(i)), word);
        try state.writeRegister(.shader, stage.programRegisterBase(), program >> 8);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var output: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        const actual = std.mem.readInt(u32, &output, .little);
        std.debug.print("packed float case {d}: actual=0x{x} expected=0x{x}\n", .{ index, actual, case.expected });
        try std.testing.expectEqual(case.expected, actual);
    }
    std.debug.print("packed float passed: MIX precision, half selection, ABS/NEG, preserved halves, packed arithmetic and inline constants\n", .{});
}

fn runSdwaProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var state = gpu.State{};
    const stage = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 7 << 1);
    for ([_]u32{ 0x10000, 4 << 16, 1, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
    const Runner = struct {
        fn check(r: *vulkan.Renderer, g: *GuestMemory, s: *gpu.State, index: usize, inputs: [3]u32, instructions: []const u32, expected: u32) !void {
            const program: u32 = 0x100 + @as(u32, @intCast(index)) * 0x100;
            for (inputs, 0..) |value, reg| {
                try s.writeRegister(.shader, stage.userDataBase() + 4 + @as(u32, @intCast(reg)), value);
                g.word(program + reg * 4, vop1(1, @intCast(reg), @intCast(4 + reg)));
            }
            for (instructions, 0..) |word, offset| g.word(program + 12 + offset * 4, word);
            const end = program + 12 + instructions.len * 4;
            g.word(end, 0xe070_0000);
            g.word(end + 4, 0x8000_0000);
            g.word(end + 8, 0xbf81_0000);
            try s.writeRegister(.shader, stage.programRegisterBase(), program >> 8);
            _ = try r.dispatchRdna2State(s, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var output: [4]u8 = undefined;
            try r.readbackGuestStorageBuffer(0x10000, &output);
            const actual = std.mem.readInt(u32, &output, .little);
            std.debug.print("SDWA case {d}: actual=0x{x} expected=0x{x}\n", .{ index, actual, expected });
            try std.testing.expectEqual(expected, actual);
        }
    };
    const expected = [_][3]u32{
        .{ 0x000000e1, 0xffffffe1, 0xaabbcce1 },
        .{ 0x0000e100, 0xffffe100, 0xaabbe1dd },
        .{ 0x00e10000, 0xffe10000, 0xaae1ccdd },
        .{ 0xe1000000, 0xe1000000, 0xe1bbccdd },
        .{ 0x000080e1, 0xffff80e1, 0xaabb80e1 },
        .{ 0x80e10000, 0x80e10000, 0x80e1ccdd },
    };
    for (expected, 0..) |modes, selection| for (modes, 0..) |value, mode| {
        const modifier: u32 = 1 | (@as(u32, @intCast(selection)) << 8) | (@as(u32, @intCast(mode)) << 11) | (6 << 16);
        try Runner.check(&renderer, &guest, &state, selection * 3 + mode, .{ 0xaabbccdd, 0x987680e1, 0 }, &.{ vop1(1, 0, 249), modifier }, value);
    };
    const Case = struct { inputs: [3]u32, code: []const u32, expected: u32 };
    const cases = [_]Case{
        .{ .inputs = .{ 0xaabbccdd, 0x40400000, 0x40a00000 }, .code = &.{ vop1(8, 0, 249), 0x00061401, vop1(8, 0, 249), 0x00061502 }, .expected = 0x00050003 },
        .{ .inputs = .{ 0x3c003800, 0x40003c00, 0x44004200 }, .code = &.{ (0x32 << 25) | (2 << 9) | 249, 0x05041501 }, .expected = 0x45003800 },
        .{ .inputs = .{ 0x3c003800, 0xc0003c00, 0x44004200 }, .code = &.{ (0x32 << 25) | (2 << 9) | 249, 0x05351501 }, .expected = 0x40003800 },
        .{ .inputs = .{ 0xaabbccdd, 0, 0x44004200 }, .code = &.{ (0x35 << 25) | (2 << 9) | 249, 0x058614f0 }, .expected = 0xaabb4000 },
        .{ .inputs = .{ 0xaabbccdd, 0, 0x44004200 }, .code = &.{ (0x35 << 25) | (2 << 9) | 249, 0x0586b5f0 }, .expected = 0x3c00ccdd }, // omod x4 then clamp
        .{ .inputs = .{ 0xaabbccdd, 0x40003800, 0 }, .code = &.{ vop1(0x54, 0, 249), 0x00051501 }, .expected = 0x3800ccdd },
        .{ .inputs = .{ 0xaabbccdd, 0x40003800, 0 }, .code = &.{ vop1(0x58, 0, 249), 0x00051501 }, .expected = 0x4400ccdd },
        .{ .inputs = .{ 0xaabbccdd, 0x3fc00000, 0 }, .code = &.{ vop1(0x0a, 0, 249), 0x00061501 }, .expected = 0x3e00ccdd },
        .{ .inputs = .{ 0xaabbccdd, 0xc0003800, 0 }, .code = &.{ vop1(0x0b, 0, 249), 0x00350601 }, .expected = 0xc0000000 },
        .{ .inputs = .{ 0xaabbccdd, 0x987680e1, 0 }, .code = &.{ 0xbefe0480, vop1(1, 0, 249), 0x00061501, 0xbefe04c1 }, .expected = 0xaabbccdd },
        .{ .inputs = .{ 0x00003c00, 0, 0 }, .code = &.{ 0xcc204000, 0x0401e4f2 }, .expected = 0x40000000 }, // MIX: f32(1) * f32(1) + f16(1)
        .{ .inputs = .{ 0x00003c00, 0, 0 }, .code = &.{ 0xcc204000, 0x1c01e4f2 }, .expected = 0x40000000 }, // MIX: all inputs f16, including inline ones
        .{ .inputs = .{ 0x3c00, 0x4000, 0x4200 }, .code = &.{ 0xd7540000, 0x040a0300 }, .expected = 0x4200 }, // max(1,2,3)
        .{ .inputs = .{ 0x3c00, 0x4000, 0x3800 }, .code = &.{ 0xd7510000, 0x040a0300 }, .expected = 0x3800 }, // min(1,2,.5)
        .{ .inputs = .{ 0x3c00, 0x4200, 0x4000 }, .code = &.{ 0xd7570000, 0x040a0300 }, .expected = 0x4000 }, // median(1,3,2)
        .{ .inputs = .{ 0x38003400, 0x3c003400, 0x40003000 }, .code = &.{ 0xd7542800, 0x040a0300 }, .expected = 0x38004000 }, // max(.5,.25,2), preserve high half
        .{ .inputs = .{ 0x38003400, 0x3c003400, 0x40003000 }, .code = &.{ 0xd7546800, 0x040a0300 }, .expected = 0x40003400 }, // same result into high half
        .{ .inputs = .{ 0x38003400, 0x3c003400, 0x40003000 }, .code = &.{ 0xd7511000, 0x040a0300 }, .expected = 0x38003000 }, // min(.25,1,.125)
        .{ .inputs = .{ 0x38003400, 0x3c003400, 0x40003000 }, .code = &.{ 0xd7573800, 0x040a0300 }, .expected = 0x38003c00 }, // median(.5,1,2)
        .{ .inputs = .{ 0x42003800, 0, 0 }, .code = &.{vop1(0x58, 0, 128)}, .expected = 0x42003c00 }, // native exp preserves a previously packed high half
        .{ .inputs = .{ 0x42003800, 0x3c00, 0x4000 }, .code = &.{(0x35 << 25) | (2 << 9) | 257}, .expected = 0x42004000 }, // native mul preserves the other weight
    };
    for (cases, 0..) |case, index| try Runner.check(&renderer, &guest, &state, 18 + index, case.inputs, case.code, case.expected);
    // VOP3 CNDMASK is a bit copy with floating-point ABS/NEG semantics.
    // Test each source's modifiers independently, including zero and NaN
    // payloads which numeric conversions must leave intact.
    for ([_]u32{ 0x8000_0000, 0xbf20_0000, 0x7fc1_2345, 0xdead_beef }, 0..) |payload, payload_index| {
        for (0..16) |modifiers| {
            for (0..2) |selected| {
                const absolute = (modifiers >> @intCast(selected * 2)) & 1 != 0;
                const negate = (modifiers >> @intCast(selected * 2 + 1)) & 1 != 0;
                var expected_bits = payload;
                if (absolute) expected_bits &= 0x7fff_ffff;
                if (negate) expected_bits ^= 0x8000_0000;
                const abs_bits: u32 = @intCast(((modifiers & 1) << 8) | (((modifiers >> 2) & 1) << 9));
                const neg_bits: u32 = @intCast((((modifiers >> 1) & 1) << 29) | (((modifiers >> 3) & 1) << 30));
                const code = [_]u32{
                    sop1(4, 6, if (selected == 0) 128 else 193),
                    0xd501_0000 | abs_bits,
                    257 | (258 << 9) | (6 << 18) | neg_bits,
                };
                try Runner.check(&renderer, &guest, &state, 80 + payload_index * 32 + modifiers * 2 + selected, .{ 0, payload, payload }, &code, expected_bits);
            }
        }
    }
    std.debug.print("SDWA passed: byte/word destinations, padding/sign/preservation, A16 coordinate packing, F16 math/modifiers and inactive EXEC\n", .{});
    std.debug.print("conditional float selection passed: both sources, ABS/NEG combinations and exact zero/NaN/integer payload bits\n", .{});
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

    // The ray traversal stack tests v60.w1 against s52.w1. Opposite-sign
    // low halves catch accidental dword comparisons or ignored SDWA selectors.
    const stack_values = [_]i16{ -32768, -1, 0, 1, 211, 212, 213, 32767 };
    for (0..64) |lane| {
        const high: u16 = @bitCast(stack_values[(lane / 2) % stack_values.len]);
        guest.word(0x12000 + lane * 4, (@as(u32, high) << 16) | ~high);
    }
    for ([_]i16{ -1, 0, 212 }) |limit| {
        @memset(guest.bytes[0x13000..0x13400], 0xcc);
        const high: u16 = @bitCast(limit);
        const stack_code = [_]u32{
            0xe030_2000,      0x8000_3c00, // load v60, indexed V#s0
            sop1(3, 52, 255), (@as(u32, high) << 16) | ~high,
            0x7d84_0080, // v_cmp_eq_u32 0, v0: establish VCC
            (0x1b << 25) | (1 << 17) | 129, // v_and_b32 v1, 1, v0
            0x7daa_0280, // v_cmpx_ne_u32 0, v1: only odd lanes
            0x7d32_68f9, 0x8505_003c, // v_cmpx_lt_i16 v60.w1, s52.w1
            0xe070_2000, 0x8001_3c00,
            0xbefe_04c1, // restore EXEC
            vop1(1, 5, 106),
            0xe070_200c, 0x8001_0500, // both CMPX instructions preserve VCC
            0xbf81_0000,
        };
        for (stack_code, 0..) |word, i| guest.word(0x200 + i * 4, word);
        try state.writeRegister(.shader, compute.programRegisterBase(), 2);
        for ([_]u32{ 0x12000, 4 << 16, 64, 0, 0x13000, 16 << 16, 64, 0 }, 0..) |word, i|
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        try renderer.readbackGuestStorageBuffer(0x13000, &output);
        for (0..64) |lane| {
            var expected: [16]u8 = @splat(0xcc);
            if (lane % 2 == 1 and stack_values[(lane / 2) % stack_values.len] < limit)
                @memcpy(expected[0..4], guest.bytes[0x12000 + lane * 4 ..][0..4]);
            std.mem.writeInt(u32, expected[12..16], if (lane == 0) 0xffff_ffff else 0, .little);
            try std.testing.expectEqualSlices(u8, &expected, output[lane * 16 ..][0..16]);
        }
    }
    std.debug.print("signed stack masks passed: high-word VGPR/SGPR LT, negative limits, inactive lanes and preserved VCC\n", .{});
    try runUnsigned64ExecProbe(allocator);
}

fn runUnsigned64ExecProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const values = [_][2]u64{
        .{ 0, 0 },                       .{ 1, 0 },                                         .{ 0, 1 },                     .{ 0x1_0000_0000, 0xffff_ffff },
        .{ 0xffff_ffff, 0x1_0000_0000 }, .{ 0x8000_0000_0000_0000, 0x7fff_ffff_ffff_ffff }, .{ 0x7fff_ffff, 0x7fff_ffff }, .{ 0xffff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff },
    };
    for ([_]u32{ 64, 256 }) |lanes| for (0..4) |encoding| {
        for (0..lanes) |lane| {
            const pair = values[(lane / 2) % values.len];
            std.mem.writeInt(u64, guest.bytes[0x10000 + lane * 16 ..][0..8], pair[0], .little);
            std.mem.writeInt(u64, guest.bytes[0x10008 + lane * 16 ..][0..8], pair[1], .little);
        }
        @memset(guest.bytes[0x12000..0x12800], 0xcc);
        const code = [_]u32{
            mubuf(0x0e, 0, 2, 0, 0)[0], mubuf(0x0e, 0, 2, 0, 0)[1], // v2:v5 = paired u64 inputs
            0x7d84_0080, // establish VCC = lane == 0
            vop2Source(0x1b, 1, 129, 0),                     0x7daa_0280, // only odd lanes before CMPX
            if (encoding == 0) 0x7de8_0902 else 0xd4f4_007e, if (encoding == 0) 0xbf80_0000 else @as(u32, if (encoding == 3) 8 else 258) | (@as(u32, if (encoding >= 2) 255 else 260) << 9),
            if (encoding >= 2) 0x7fff_ffff else 0xbf80_0000, vop1(1, 6, 255),
            0x1234_5678,                                     mubuf(0x1c, 0, 6, 0, 4)[0],
            mubuf(0x1c, 0, 6, 0, 4)[1],
            sop1(4, 126, 193),          vop1(1, 6, 106), // restore EXEC, preserve previous VCC
            mubuf(0x1c, 4, 6, 0, 4)[0], mubuf(0x1c, 4, 6, 0, 4)[1],
            0xbf81_0000,
        };
        const program: u32 = 0x100 + @as(u32, @intCast(encoding)) * 0x100;
        for (code, 0..) |word, index| guest.word(program + index * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, program >> 8);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, 10 << 1);
        for ([_]u32{ 0x10000, 16 << 16, lanes, 0, 0x12000, 8 << 16, lanes, 0, 0, 1 }, 0..) |word, index|
            try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        const report = try renderer.dispatchRdna2State(&state, .{ lanes, 1, 1 }, .{ 1, 1, 1 });
        try std.testing.expect(report.spirv_words != 0);
        var output: [256 * 8]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x12000, output[0 .. lanes * 8]);
        for (0..lanes) |lane| {
            const pair = values[(lane / 2) % values.len];
            const left: u64 = if (encoding == 3) 0x1_0000_0000 else pair[0];
            const right: u64 = if (encoding >= 2) 0x7fff_ffff else pair[1];
            const expected: u32 = if (lane % 2 == 1 and left > right) 0x1234_5678 else 0xcccc_cccc;
            try std.testing.expectEqual(expected, std.mem.readInt(u32, output[lane * 8 ..][0..4], .little));
            try std.testing.expectEqual(@as(u32, if (lane == 0) 0xffff_ffff else 0), std.mem.readInt(u32, output[lane * 8 + 4 ..][0..4], .little));
        }
    };
    std.debug.print("u64 greater CMPX passed: both encodings, high-word ordering, equality, literal/SGPR inputs, inactive lanes and preserved VCC at 64/256 lanes\n", .{});
}

fn runImageScratchProbe(allocator: std.mem.Allocator) !void {
    const Memory = SizedGuestMemory(24 * 1024 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 8), vop1(1, 1, 9), vop1(1, 2, 10),
        0xf020_0108, 0x0000_0200, // write one RGBA8_UINT pixel through T#s0
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 11 << 1);
    var descriptors = [_][8]u32{
        imageDescriptorWords(0x40000, 257, 129),
        imageDescriptorWords(0x100000, 385, 97),
        // Exceed the parallel fingerprint threshold on both staging and
        // writeback; cache digests must agree when worker counts change.
        imageDescriptorWords(0x400000, 2049, 1025),
    };
    descriptors[1][3] |= @as(u32, @intFromEnum(gpu.resources.TileMode.render_target)) << 20;
    const previous_participants = gpu.parallel_copy.guest_copy_pool.participants.load(.acquire);
    defer gpu.parallel_copy.guest_copy_pool.participants.store(previous_participants, .release);
    for ([_]bool{ false, true, true, false, true }, 0..) |enabled, pass| {
        gpu.parallel_copy.guest_copy_pool.participants.store(if (pass % 2 == 0) 4 else 1, .release);
        renderer.image_scratch.enabled = enabled;
        for (descriptors, 0..) |words, index| {
            const descriptor = try gpu.resources.decodeImageDescriptor(&words);
            const texture = try gpu.TextureLayout.fromImage(descriptor);
            const view = try texture.subresource(0, 0, 1);
            const address: usize = @intCast(descriptor.address);
            const size: usize = @intCast(texture.required_source_bytes);
            const sentinel: u8 = @intCast(50 + pass * 13 + index);
            @memset(guest.bytes[address..][0..size], sentinel);
            for (words, 0..) |word, component| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(component)), word);
            const x: u32 = if (pass % 2 == 0) descriptor.width - 1 else 0;
            const y: u32 = if (pass % 2 == 0) descriptor.height - 1 else 0;
            const value: u8 = @intCast(171 + pass + index);
            try state.writeRegister(.shader, compute.userDataBase() + 8, x);
            try state.writeRegister(.shader, compute.userDataBase() + 9, y);
            try state.writeRegister(.shader, compute.userDataBase() + 10, value);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            if (pass == 2) {
                const Failure = struct {
                    fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
                        return false;
                    }
                };
                renderer.guest_memory.?.write = Failure.write;
                try std.testing.expectError(error.GuestMemoryWriteFailed, renderer.flushPendingGuestWrites());
                renderer.guest_memory.?.write = Memory.write;
            }
            try renderer.flushPendingGuestWrites();
            const pixel: usize = @intCast(try view.sourceByteOffset(x, y, 0, 0));
            try std.testing.expectEqualSlices(u8, &.{ value, 0, 0, 0 }, guest.bytes[address + pixel ..][0..4]);
            // Every other logical pixel and all tiled/row padding must survive
            // pooling, CPU updates, partial GPU writes and callback failures.
            try std.testing.expect(std.mem.allEqual(u8, guest.bytes[address..][0..pixel], sentinel));
            try std.testing.expect(std.mem.allEqual(u8, guest.bytes[address + pixel + 4 ..][0 .. size - pixel - 4], sentinel));
            if (index == 2) {
                gpu.parallel_copy.guest_copy_pool.participants.store(if (pass % 2 == 0) 1 else 4, .release);
                const uploaded = renderer.frame_profile.texture_upload_bytes;
                _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
                // Publishing a partial write and switching hash workers must
                // still reuse the image when the guest bytes did not change.
                try std.testing.expectEqual(uploaded, renderer.frame_profile.texture_upload_bytes);
                try renderer.flushPendingGuestWrites();
            }
        }
    }
    try std.testing.expect(renderer.image_scratch.entries[0].len != 0);
    std.debug.print("image scratch passed: alternating pooled/unpooled extents, linear/RB+ padding, native updates, partial GPU writes and failed-write retry\n", .{});
}

fn runSampledDccClearProbe(allocator: std.mem.Allocator) !void {
    const Memory = SizedGuestMemory(2 * 1024 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 255), 0x3e80_0000, vop1(1, 1, 255), 0x3f40_0000,
        0xf09c_0f0a, 0x0040_0200, 1, // Sample RGBA into v2:v5.
        0xe078_0000, 0x8003_0200, 0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    const source = 0x20000;
    const metadata = 0x120000;
    for ([_]u16{ 56, 71 }) |format| {
        var words = sampledImageDescriptorWords(source, 256, 128);
        words[1] = (words[1] & ~@as(u32, 0x1ff00000)) | (@as(u32, format) << 20);
        words[3] |= @as(u32, @intFromEnum(gpu.resources.TileMode.render_target)) << 20;
        words[7] = metadata >> 16;
        const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
        const surface_bytes: usize = @intCast(texture.required_source_bytes);
        const key_bytes = std.math.divCeil(usize, surface_bytes, 256) catch unreachable;
        // The unchanged base contains real texels different from every clear.
        if (format == 56) @memset(guest.bytes[source..][0..surface_bytes], 64) else {
            var offset: usize = 0;
            while (offset < surface_bytes) : (offset += 2)
                std.mem.writeInt(u16, guest.bytes[source + offset ..][0..2], 0x3400, .little);
        }
        for ([_]bool{ true, false }) |alpha_msb| {
            words[6] = (1 << 21) | (@as(u32, @intFromBool(alpha_msb)) << 22) | (((metadata >> 8) & 255) << 24);
            const userdata = words ++ [_]u32{ 0, 0, 0, 0, 0x10000, 16 << 16, 1, 0 };
            for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
            for ([_]u8{ 0x40, 0x80, 0xc0, 0x00, 0x40, 0xff, 0x20 }) |key| {
                @memset(guest.bytes[metadata..][0..key_bytes], key);
                _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
                var output: [16]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(0x10000, &output);
                for (0..4) |channel| {
                    const expected: f32 = if (key == 0xff or key == 0x20)
                        (if (format == 56) 64.0 / 255.0 else 0.25)
                    else if (key & @as(u8, if (channel == (if (alpha_msb) @as(usize, 3) else 0)) 0x40 else 0x80) != 0) 1 else 0;
                    std.testing.expectApproxEqAbs(expected, @as(f32, @bitCast(std.mem.readInt(u32, output[channel * 4 ..][0..4], .little))), 0.00001) catch |err| {
                        std.debug.print("DCC sample mismatch format={d} alpha_msb={any} key=0x{x} channel={d}\n", .{ format, alpha_msb, key, channel });
                        return err;
                    };
                }
                const uploaded = renderer.frame_profile.texture_upload_bytes;
                // A fixed clear is defined entirely by metadata. Changing the
                // hidden base pixels must neither affect it nor upload again.
                const fixed_clear = key != 0xff and key != 0x20;
                if (fixed_clear) guest.bytes[source] ^= 1;
                _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
                if (fixed_clear) guest.bytes[source] ^= 1;
                try std.testing.expectEqual(uploaded, renderer.frame_profile.texture_upload_bytes);
            }
        }
    }
    std.debug.print("sampled DCC clears passed: RGBA8/RGBA16F fixed clears, alpha placement, metadata-only updates, cache hits and raw fallback\n", .{});
}

fn runSampledViewReuseProbe(allocator: std.mem.Allocator) !void {
    try runSampledViewReuseCase(allocator, false);
    try runSampledViewReuseCase(allocator, true);
}

fn runSampledCacheBudgetProbe(allocator: std.mem.Allocator) !void {
    try runSampledCacheBudgetCase(allocator, .one_byte);
    try runSampledCacheBudgetCase(allocator, .bounded_sync);
    try runSampledCacheBudgetCase(allocator, .bounded_async);
    try runSampledCacheBudgetCase(allocator, .replace_sync);
}

fn runSampledCacheBudgetCase(allocator: std.mem.Allocator, mode: enum { one_byte, bounded_sync, bounded_async, replace_sync }) !void {
    const bounded_case = mode == .bounded_sync or mode == .bounded_async;
    const deferred_retirement = mode == .bounded_async;
    const replace_contents = mode == .replace_sync;
    const previous_slack = vulkan.backend.sampled_retirement_slack_bytes;
    defer vulkan.backend.sampled_retirement_slack_bytes = previous_slack;
    vulkan.backend.sampled_retirement_slack_bytes = if (deferred_retirement) 64 * 1024 * 1024 else 0;
    const Memory = SizedGuestMemory(512 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    var renderer = try vulkan.Renderer.init(allocator, .{ .defer_small_storage_writes = true });
    defer renderer.deinit();
    const Context = struct {
        guest: *Memory,
        renderer: *vulkan.Renderer,
        advance_at: u64 = 0,
        advances: usize = 0,
        fn read(raw: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.advance_at != 0 and address <= self.advance_at and self.advance_at - address < bytes.len) {
                self.renderer.frame_sequence += 1;
                self.advance_at = 0;
                self.advances += 1;
            }
            return Memory.read(self.guest, address, bytes);
        }
        fn write(raw: ?*anyopaque, address: u64, bytes: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return Memory.write(self.guest, address, bytes);
        }
    };
    var context = Context{ .guest = guest, .renderer = &renderer };
    const backend = renderer.dcbBackend(.{ .context = &context, .read = Context.read, .write = Context.write });
    // Two images prepared by one dispatch must survive even a one-byte soft
    // budget. Advancing the publication counter between them is not a batch end.
    renderer.sampled_image_cache_budget_bytes = if (replace_contents) 1024 * 1024 else 1;
    const store_a = mubuf(0x1e, 0, 2, 0, 20);
    const store_b = mubuf(0x1e, 16, 6, 0, 20);
    const code = [_]u32{
        vop1(1, 0, 240),                 vop1(1, 1, 240),
        0xf09c_0f0a,                     0x0080_0200,
        1,                               0xf09c_0f0a,
        0x0082_0600,                     1,
        store_a[0] & ~@as(u32, 1 << 13), store_a[1],
        store_b[0] & ~@as(u32, 1 << 13), store_b[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 24 << 1);
    const rounds: usize = if (bounded_case) 12 else 3;
    for (0..rounds) |round| {
        const source: u32 = @intCast(0x20000 + (if (replace_contents) @as(usize, 0) else round) * 0x200);
        guest.word(source, 0xff60_4020 + @as(u32, @intCast(round)));
        guest.word(source + 0x100, 0xffc0_a080 + @as(u32, @intCast(round)));
        if (replace_contents) {
            const first = guest.bytes[source..][0..4].*;
            const second = guest.bytes[source + 0x100 ..][0..4].*;
            try std.testing.expect(backend.vtable.write(backend.context, source, &first));
            try std.testing.expect(backend.vtable.write(backend.context, source + 0x100, &second));
        }
        context.advance_at = source + 0x100;
        const userdata = sampledImageDescriptorWords(source, 1, 1) ++
            sampledImageDescriptorWords(source + 0x100, 1, 1) ++ [_]u32{ 0, 0, 0, 0, @intCast(0x10000 + round * 0x100), 0, 32, 0 };
        for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try std.testing.expectEqual(if (bounded_case) @min((round + 1) * 2, 16) else @as(usize, 2), renderer.sampled_image_cache.items.len);
        var total: u64 = 0;
        for (renderer.sampled_image_cache.items) |entry| {
            try std.testing.expect(entry.image.allocation_bytes != 0);
            total += entry.image.allocation_bytes;
            if (entry.guest_address >= source) try std.testing.expectEqual(renderer.sampled_image_batch, entry.last_used_batch);
        }
        try std.testing.expectEqual(total, renderer.sampled_image_cache_bytes);
        try std.testing.expect(renderer.pending_command_buffers.items.len != 0);
        // Size both comparison cases from real allocation requirements: sixteen
        // resident images plus at most two retired images awaiting consumers.
        if (bounded_case and round == 0) renderer.sampled_image_cache_budget_bytes = total * 8;
        if (!replace_contents) try std.testing.expect(renderer.pending_sampled_image_bytes <= renderer.sampled_image_cache_budget_bytes / 8);
    }
    try std.testing.expectEqual(rounds, context.advances);
    try std.testing.expectEqual(@as(u64, if (replace_contents) 0 else if (bounded_case) 8 else 4), renderer.frame_profile.texture_evictions);
    // Updating texture contents below the budget never forced retirement waits
    // in the baseline, even when the old images still have queued consumers.
    if (replace_contents) try std.testing.expectEqual(@as(u64, 0), renderer.frame_profile.sampled_retire_wait_calls);
    if (deferred_retirement) try std.testing.expect(renderer.frame_profile.sampled_retire_wait_calls < renderer.frame_profile.texture_evictions);
    for (0..rounds) |round| {
        var output: [32]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000 + round * 0x100, &output);
        for (0..8) |component| {
            const channel = component % 4;
            const expected: f32 = if (channel == 3) 1 else @as(f32, @floatFromInt(
                (if (component < 4) @as(usize, 32) else 128) + channel * 32 + (if (channel == 0) round else 0),
            )) / 255.0;
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[component * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
    }
    try std.testing.expectEqual(@as(u64, 0), renderer.pending_sampled_image_bytes);
    std.debug.print("sampled cache budget passed: mode={s}, queued consumers, batch protection, exact allocation accounting, evictions={d} retirement waits={d}\n", .{ @tagName(mode), renderer.frame_profile.texture_evictions, renderer.frame_profile.sampled_retire_wait_calls });
}

fn runSampledViewReuseCase(allocator: std.mem.Allocator, canonical_aliases: bool) !void {
    const Memory = SizedGuestMemory(2 * 1024 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_canonical_image_aliases = canonical_aliases });
    defer renderer.deinit();
    const backend = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 255), 0x3e80_0000, vop1(1, 1, 255), 0x3f40_0000,
        0xf09c_0f0a,     0x0040_0200, 1,               0xe078_0000,
        0x8003_0200,     0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    for ([_]u16{ 56, 169, 173 }, 0..) |format, format_index| {
        const source: u32 = @intCast(0x20000 + format_index * 0x40000);
        var words = sampledImageDescriptorWords(source, 32, 32);
        words[1] = (words[1] & ~@as(u32, 0x1ff00000)) | (@as(u32, format) << 20);
        words[3] |= (2 << 16) | (@as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20);
        words[5] = 2 << 4;
        const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
        for (0..2) |revision| {
            // Distinct mip colours expose views accidentally restricted to LOD 0.
            for (0..3) |lod| {
                const view = try texture.subresource(@intCast(lod), 0, 1);
                const extent: u32 = @as(u32, 32) >> @as(u5, @intCast(lod));
                const elements = if (format == 56) extent else extent / 4;
                for (0..elements) |y| for (0..elements) |x| {
                    const offset: usize = source + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                    if (format == 56) {
                        @memcpy(guest.bytes[offset..][0..4], &[_]u8{ @intCast(32 + revision * 32 + lod * 32), 128, 192, 255 });
                    } else {
                        const color_offset = offset + @as(usize, if (format == 173) 8 else 0);
                        if (format == 173) @memcpy(guest.bytes[offset..][0..8], &[_]u8{ 255, 255, 0, 0, 0, 0, 0, 0 });
                        const rgb565: u16 = (@as(u16, @intCast(4 + revision * 4 + lod * 4)) << 11) | (32 << 5) | 24;
                        std.mem.writeInt(u16, guest.bytes[color_offset..][0..2], rgb565, .little);
                        std.mem.writeInt(u16, guest.bytes[color_offset + 2 ..][0..2], rgb565, .little);
                        @memset(guest.bytes[color_offset + 4 ..][0..4], 0);
                    }
                };
            }
            const authored = try allocator.dupe(u8, guest.bytes[source..][0..@intCast(texture.required_source_bytes)]);
            defer allocator.free(authored);
            try std.testing.expect(backend.vtable.write(backend.context, source, authored));
            const before_uploads = renderer.sampled_image_uploads;
            for (0..8) |variant| {
                var image = words;
                const srgb = variant % 3 != 0;
                const swap = variant >= 3;
                const lod: u32 = if (variant >= 6) 2 else 0;
                if (variant % 3 == 2) image[1] = (image[1] & ~@as(u32, 0x1ff00000)) | (@as(u32, if (format == 56) 130 else format + 1) << 20);
                if (swap) image[3] = (image[3] & ~@as(u32, 0xfff)) | 6 | (5 << 3) | (4 << 6) | (7 << 9);
                const sampler = [_]u32{ if (variant % 3 == 1) 1 << 20 else 0, (lod * 256) | ((lod * 256) << 12), 0, 0 };
                const userdata = image ++ sampler ++ [_]u32{ 0x10000, 16 << 16, 1, 0 };
                for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
                _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
                var output: [16]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(0x10000, &output);
                const r: f32 = if (format == 56) @as(f32, @floatFromInt(32 + revision * 32 + lod * 32)) / 255.0 else @as(f32, @floatFromInt(4 + revision * 4 + lod * 4)) / 31.0;
                const rgb: [3]f32 = if (format == 56) .{ r, 128.0 / 255.0, 192.0 / 255.0 } else .{ r, 32.0 / 63.0, 24.0 / 31.0 };
                for (0..4) |channel| {
                    var expected: f32 = if (channel == 3) 1 else rgb[if (swap) 2 - channel else channel];
                    if (srgb and channel != 3) expected = if (expected <= 0.04045) expected / 12.92 else std.math.pow(f32, (expected + 0.055) / 1.055, 2.4);
                    const actual: f32 = @bitCast(std.mem.readInt(u32, output[channel * 4 ..][0..4], .little));
                    std.testing.expectApproxEqAbs(expected, actual, 0.008) catch |err| {
                        std.debug.print("sampled view mismatch format={d} revision={d} variant={d} channel={d}\n", .{ format, revision, variant, channel });
                        std.debug.print("source head={any} bytes={d} uploads={d}->{d} probes={d}\n", .{ guest.bytes[source..][0..8].*, texture.required_source_bytes, before_uploads, renderer.sampled_image_uploads, renderer.texture_probe_count });
                        for (renderer.sampled_image_cache.items) |cached| std.debug.print("cached @0x{x} hash={x} generation={d}\n", .{ cached.guest_address, cached.content_hash, cached.source_generation });
                        return err;
                    };
                }
                try std.testing.expectEqual(before_uploads + 1, renderer.sampled_image_uploads);
                try std.testing.expectEqual(format_index + 1, renderer.sampled_image_cache.items.len);
            }
        }
    }
    std.debug.print("sampled view reuse passed: RGBA8/BC1/BC3 linear/sRGB, channel swizzles, mip selection, CPU updates and one allocation per source\n", .{});
}

fn runSampledScratchProbe(allocator: std.mem.Allocator) !void {
    const Memory = SizedGuestMemory(8 * 1024 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 255), 0x3e80_0000,
        vop1(1, 1, 255), 0x3f40_0000,
        0xf09c_010a,     0x0040_0200,
        1,               0xe070_0000,
        0x8003_0200,     0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    var images = [_][8]u32{
        sampledImageDescriptorWords(0x200000, 257, 129),
        sampledImageDescriptorWords(0x200000, 385, 97),
        sampledImageDescriptorWords(0x200000, 512, 512),
    };
    images[1][3] |= @as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20;
    images[2][3] |= (3 << 16) | (@as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20);
    images[2][5] = 3 << 4;
    for ([_]bool{ false, true, true, false, true }, 0..) |enabled, pass| {
        renderer.image_scratch.enabled = enabled;
        for (images, 0..) |words, index| {
            const descriptor = try gpu.resources.decodeImageDescriptor(&words);
            const texture = try gpu.TextureLayout.fromImage(descriptor);
            const value: u8 = @intCast(30 + pass * 31 + index * 7);
            @memset(guest.bytes[0x200000..][0..@intCast(texture.required_source_bytes)], value);
            var userdata: [16]u32 = @splat(0);
            @memcpy(userdata[0..8], &words);
            @memcpy(userdata[12..16], &[_]u32{ 0x10000, 4 << 16, 1, 0 });
            for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var output: [4]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x10000, &output);
            try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(value)) / 255.0, @as(f32, @bitCast(std.mem.readInt(u32, &output, .little))), 0.00001);
            const uploaded = renderer.frame_profile.texture_upload_bytes;
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            try std.testing.expectEqual(uploaded, renderer.frame_profile.texture_upload_bytes);
        }
    }
    try std.testing.expect(renderer.image_scratch.entries[0].len + renderer.image_scratch.entries[1].len >= 1024 * 1024);
    std.debug.print("sampled scratch passed: pooled/unpooled linear/tiled/mip uploads, changing sizes and CPU content, unchanged cache reuse\n", .{});
}

fn runZeroDepthSampleProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = SizedGuestMemory(262144){};
    const backend = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 255), 0x3f000000,
        vop1(1, 1, 255), 0x3f000000,
        0xf09c_010a, 0x0040_0200, 0x0000_0001, // Sample depth with s8 sampler.
        0xe070_0000, 0x8003_0200, 0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    for ([_]u16{ 7, 22 }) |format| {
        var image = sampledImageDescriptorWords(0x10000, 32, 32);
        image[1] = (image[1] & ~@as(u32, 0x1ff00000)) | (@as(u32, format) << 20);
        image[3] |= @as(u32, @intFromEnum(gpu.resources.TileMode.depth)) << 20;
        const view = try (try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image))).subresource(0, 0, 1);
        const userdata = image ++ [_]u32{ 0, 0, 0, 0, 0x8000, 4 << 16, 1, 0 };
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, @intCast(0x240 + index), word);
        for ([_]u32{ 0, 1, 0 }) |value| {
            @memset(guest.bytes[0x10000..0x30000], 0);
            for (0..32) |y| for (0..32) |x| {
                const offset: usize = 0x10000 + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                if (format == 7) {
                    std.mem.writeInt(u16, guest.bytes[offset..][0..2], if (value == 0) 0 else 65535, .little);
                } else guest.word(offset, if (value == 0) 0 else 0x3f800000);
            };
            // Publish the authored texture update through the renderer boundary.
            const authored = try allocator.dupe(u8, guest.bytes[0x10000..0x30000]);
            defer allocator.free(authored);
            try std.testing.expect(backend.vtable.write(backend.context, 0x10000, authored));
            guest.word(0x8000, 0xdeadbeef);
            const report = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            try std.testing.expect(report.spirv_words != 0);
            var output: [4]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x8000, &output);
            try std.testing.expectEqual(@as(u32, if (value == 0) 0 else 0x3f800000), std.mem.readInt(u32, &output, .little));
        }
    }
    std.debug.print("zero depth samples passed: D16/D32 tiled uploads, zero/one/zero updates and cached views without resident attachments\n", .{});
}

fn runDepthStorageProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const load = [_]u32{
        vop1(1, 0, 128), vop1(1, 1, 128),
        0xf000_0108, 0x0000_0200, // image_load depth v2, T#s0
        0xf000_0108, 0x0002_0300, // image_load stencil v3, T#s8
        0xe074_0000, 0x8004_0200, // buffer_store_dwordx2 v2:v3, V#s16
        0xbf81_0000,
    };
    const store = [_]u32{
        vop1(1, 0, 128), vop1(1, 1, 128),
        vop1(1, 2, 255), 0x3f00_0000,
        0xf020_0108,     0x0000_0200,
        vop1(1, 2, 255), 0x23,
        0xf020_0108,     0x0002_0200,
        0xbf81_0000,
    };
    for (load, 0..) |word, index| guest.word(0x100 + index * 4, word);
    for (store, 0..) |word, index| guest.word(0x400 + index * 4, word);
    var depth = sampledImageDescriptorWords(0x1000, 32, 32);
    depth[1] = (depth[1] & ~@as(u32, 0x1ff00000)) | (22 << 20);
    var stencil = sampledImageDescriptorWords(0x3000, 32, 32);
    stencil[1] = (stencil[1] & ~@as(u32, 0x1ff00000)) | (5 << 20);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 20 << 1);
    const userdata = depth ++ stencil ++ [_]u32{ 0x8000, 8 << 16, 1, 0 };
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    for ([_]f32{ 0.25, 0.75 }) |value| {
        try renderer.probeDepthStencilClear(value, 0x48);
        for (0..2) |_| {
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var bytes: [8]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x8000, &bytes);
            try std.testing.expectEqual(@as(u32, @bitCast(value)), std.mem.readInt(u32, bytes[0..4], .little));
            try std.testing.expectEqual(@as(u32, 0x48), std.mem.readInt(u32, bytes[4..8], .little));
        }
        // The hand-off works with CPU depth transfer and canonical aliases off.
        try std.testing.expect(std.mem.allEqual(u8, guest.bytes[0x1000..0x2000], 0));
        try std.testing.expect(std.mem.allEqual(u8, guest.bytes[0x3000..0x3400], 0));
    }
    try state.writeRegister(.shader, compute.programRegisterBase(), 4);
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    const result = try renderer.probeDepthStencilValues();
    try std.testing.expectEqual(@as(f32, 0.5), result.depth);
    try std.testing.expectEqual(@as(u8, 0x23), result.stencil);
    try renderer.probeIndependentDepthStencilPlanes();
    std.debug.print("depth storage passed: current D32/S8 reads, repeated clears and compute writes returned to the attachment\n", .{});
}

fn runResetDepthExtentProbe(allocator: std.mem.Allocator) !void {
    try runResetDepthExtentCase(allocator, false);
    try runResetDepthExtentCase(allocator, true);
    std.debug.print("Reset depth-only extents passed: viewport/scissor recovery, raster/MRTZ depth, changing scalars and depth samples across the attachment\n", .{});
}

fn runResetDepthExtentCase(allocator: std.mem.Allocator, fragment_depth: bool) !void {
    for ([_]bool{ true, false }) |with_viewport| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        // Cover the target with W=2 and Z from USER_DATA. Changing Z between
        // draws also checks scalar uploads in the depth-only path.
        const vertex = [_]u32{
            0x34020a81,       0x36040a82,       0x36020282,    0x7e040d02, 0x7e060d01,
            0xd5410001,       0x03ce04f4,       0xd5410002,    0x03ce06f4, vop1(1, 0, 244),
            vop2(8, 1, 1, 0), vop2(8, 2, 2, 0), vop1(1, 3, 0), 0xf80008cf, 0x00030102,
            0xbf810000,
        };
        const fragment = if (fragment_depth)
            [_]u32{ vop1(1, 0, 0), 0xf8000881, 0, 0xbf810000 } // EXP MRTZ.x from USER_DATA, no color export.
        else
            [_]u32{ vop1(1, 0, 242), 0xf800080f, 0, 0xbf810000 };
        for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        var state = gpu.State{};
        for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, program| {
            try state.writeRegister(.shader, stage.programRegisterBase(), program);
            try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        }
        const context = [_][2]u32{
            .{ 0x08e, 0 },               .{ 0x007, 0 },    .{ 0x010, 3 },               .{ 0x011, 0 },
            .{ 0x012, 0x10 },            .{ 0x014, 0x10 }, .{ 0x00b, 0x3f800000 },      .{ 0x200, 6 | (1 << 4) },
            .{ 0x204, 1 << 19 },         .{ 0x205, 0 },    .{ 0x202, 0xcc0010 },        .{ 0x000, 0 },
            .{ 0x1e0, 0 },               .{ 0x00c, 0 },    .{ 0x00d, 32 | (32 << 16) }, .{ 0x094, 1 << 31 },
            .{ 0x095, 32 | (32 << 16) },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        if (fragment_depth) try state.writeRegister(.context, 0x200, 6 | (7 << 4)); // ALWAYS permits rising and falling depth.
        if (with_viewport) {
            for ([_]f32{ 16, 16, -16, 16, 1, 0 }, 0..) |value, i|
                try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        }
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        const points = [_][2]u8{ .{ 0, 0 }, .{ 31, 0 }, .{ 16, 16 }, .{ 0, 31 }, .{ 31, 31 } };
        for (points, 0..) |point, i| {
            const code = [_]u32{
                vop1(1, 0, 128 + @as(u9, point[0])),    vop1(1, 1, 128 + @as(u9, point[1])),
                0xf0000108,                             0x00000200,
                0xe0700000 | @as(u32, @intCast(i * 4)), 0x80020200,
            };
            for (code, 0..) |word, j| guest.word(0x100 + (i * code.len + j) * 4, word);
        }
        guest.word(0x100 + points.len * 24, 0xbf810000);
        var depth = sampledImageDescriptorWords(0x1000, 32, 32);
        depth[1] = (depth[1] & ~@as(u32, 0x1ff00000)) | (22 << 20);
        const userdata = depth ++ [_]u32{ 0x8000, 4 << 16, points.len, 0 };
        try state.writeRegister(.shader, 0x20c, 1);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, 12 << 1);
        for (userdata, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
        const depths: []const f32 = if (fragment_depth) &.{ 0.75, 0.25, 0.5, 0, 0.75 } else &.{ 0.5, 0.25 };
        for (depths) |z| {
            // MRTZ must replace the triangle's fixed zero depth. Cached
            // pipelines must see current scalar data, including authored zero.
            try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.userDataBase(), @bitCast(if (fragment_depth) @as(f32, 0) else z));
            try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase(), @bitCast(z));
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
            if (renderer.last_draw_error) |err| return err;
            try std.testing.expectEqual(@as(usize, 1), renderer.depth_targets.items.len);
            try std.testing.expectEqual(@as(u32, 32), renderer.depth_targets.items[0].target.width);
            try std.testing.expectEqual(@as(u32, 32), renderer.depth_targets.items[0].target.height);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var bytes: [points.len * 4]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x8000, &bytes);
            for (points, 0..) |_, i| try std.testing.expectEqual(@as(u32, @bitCast(if (fragment_depth) z else z / 2)), std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
        }
    }
}

fn runStorageImageReuseProbe(allocator: std.mem.Allocator) !void {
    for ([_]usize{ 320, 1152 }) |count| try runStorageImageReuseCase(allocator, count, 1280 * 1024 * 1024);
    try runStorageImageReuseCase(allocator, 320, 64 * 4);
    std.debug.print("storage image reuse passed: 320 resident views, 1152 queued writes, and byte-budget eviction\n", .{});
}

fn runStorageImageReuseCase(allocator: std.mem.Allocator, count: usize, byte_budget: usize) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .storage_image_cache_limit = byte_budget });
    defer renderer.deinit();
    var guest = SizedGuestMemory(512 * 1024){};
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
        try state.writeRegister(.shader, compute.userDataBase() + 16, @intCast(42 + pair % 200));
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    }
    // Earlier dirty views must remain on the GPU until a CPU consumer asks.
    try std.testing.expectEqual(@min(@as(usize, 1024), count, byte_budget / 4), renderer.storage_image_cache.items.len);
    try std.testing.expect(renderer.storage_image_cache_bytes <= byte_budget);
    if (count == 320 and count * 4 <= byte_budget) try std.testing.expect(std.mem.allEqual(u8, guest.bytes[0x4000 .. 0x4000 + count * 256], 0));
    var pixel: [4]u8 = undefined;
    // Check every dispatch, including views evicted while later commands were
    // still being prepared. A capacity fallback must not silently drop writes.
    for (0..count) |i| {
        try std.testing.expect(backend.vtable.read(backend.context, 0x4000 + i * 256, &pixel));
        try std.testing.expectEqualSlices(u8, &.{ @intCast(42 + (i / 2) % 200), 0, 0, 0 }, &pixel);
    }
    for (renderer.storage_image_cache.items) |cached| try std.testing.expectEqual(@as(usize, 0), cached.pin_count);
}

fn runFragmentCoverageProbe(allocator: std.mem.Allocator) !void {
    for (0..3) |case| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        const vertex = [_]u32{
            vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
            vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
            vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
            0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 255),  0x3e80_0000,
            vop1(1, 8, 242), 0xf800_08cf,      0x0807_0605,      0xf800_0201,
            0x0000_0005,     0xbf81_0000,
        };
        // The text alpha-test idiom saves EXEC, removes rejected lanes,
        // resumes WQM for derivatives, then publishes the saved mask via EXP.VM.
        var fragment = [_]u32{
            0xbea4_047e,     0xbefe_0a7e,     0xc808_0000,     0xc809_0001,
            vop1(1, 3, 128), 0x7c02_0702,     0x8aa4_6a24,     0xbf84_0007,
            0xbefe_0a24,     vop1(1, 0, 242), vop1(1, 1, 128), 0xbefe_0424,
            0xf800_180f,     0x0001_0100,     0xbf81_0000,     0xbefe_0480,
            0xf800_1800,     0,               0xbf81_0000,
        };
        if (case == 0) fragment[7] = 0xbf80_0000; // straight-line mixed coverage
        if (case == 2) fragment[3] = vop1(1, 2, 243); // all fragments rejected
        const blue = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 242), 0xf800_180f, 0x0101_0000, 0xbf81_0000 };
        for (vertex, 0..) |word, i| {
            guest.word(0x700 + i * 4, word);
            guest.word(0xc00 + i * 4, if (i == 15) 0x3f40_0000 else word);
        }
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        for (blue, 0..) |word, i| guest.word(0xb00 + i * 4, word);
        var state = gpu.State{};
        const vs = gpu.resources.ShaderStage.vertex.programRegisterBase();
        const ps = gpu.resources.ShaderStage.pixel.programRegisterBase();
        try state.writeRegister(.shader, vs, 7);
        try state.writeRegister(.shader, vs + 1, 0);
        try state.writeRegister(.shader, ps, 9);
        try state.writeRegister(.shader, ps + 1, 0);
        const context = [_][2]u32{
            .{ 0x318, 0x20 },            .{ 0x319, 7 },               .{ 0x31b, 0 },               .{ 0x31c, 10 << 2 },         .{ 0x31d, 0 },
            .{ 0x390, 0 },               .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },         .{ 0x08e, 0xf },             .{ 0x00c, 0 },
            .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },         .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 },               .{ 0x205, 0 },
            .{ 0x204, 1 << 19 },         .{ 0x202, 0xcc0010 },        .{ 0x000, 0 },               .{ 0x007, 63 | (63 << 16) }, .{ 0x012, 0x80 },
            .{ 0x014, 0x80 },            .{ 0x01a, 0 },               .{ 0x01c, 0 },               .{ 0x011, 1 << 29 },         .{ 0x010, 0x183 },
            .{ 0x200, 0x16 },            .{ 0x00b, 0x3f800000 },      .{ 0x191, 0 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        for ([_]f32{ 32, 32, -32, 32, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        const draw = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
        _ = try executor.execute(&draw);
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        // Rejecting alpha-tested fragments must preserve the target's old color.
        const left = 0x2000 + (32 * 64 + 24) * 4;
        const right = 0x2000 + (32 * 64 + 40) * 4;
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, guest.bytes[left..][0..4], .little));
        try std.testing.expectEqual(@as(u32, if (case == 2) 0 else 0xff0000ff), std.mem.readInt(u32, guest.bytes[right..][0..4], .little));
        // A later triangle behind the text proves rejected pixels also left
        // depth untouched; writing transparent black would fail this check.
        try state.writeRegister(.shader, vs, 0xc);
        try state.writeRegister(.shader, ps, 0xb);
        _ = try executor.execute(&draw);
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, guest.bytes[left..][0..4], .little));
        try std.testing.expectEqual(@as(u32, if (case == 2) 0xffff0000 else 0xff0000ff), std.mem.readInt(u32, guest.bytes[right..][0..4], .little));
    }
    std.debug.print("Fragment coverage passed: straight/branched alpha test, null export, retained color and depth\n", .{});
}

fn runStencilOnlyUiProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_depth_transfer = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const vertex = [_]u32{
        vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
        vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
        vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
        0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 255),  0x3e80_0000,
        vop1(1, 8, 242), 0xf800_08cf,      0x0807_0605,      0xf800_0201,
        0x0000_0005,     0xbf81_0000,
    };
    // The text alpha-test idiom saves EXEC, removes rejected lanes,
    // resumes WQM for derivatives, then publishes the saved mask via EXP.VM.
    const fragment = [_]u32{
        0xbea4_047e,     0xbefe_0a7e,     0xc808_0000,     0xc809_0001,
        vop1(1, 3, 128), 0x7c02_0702,     0x8aa4_6a24,     0xbf84_0007,
        0xbefe_0a24,     vop1(1, 0, 242), vop1(1, 1, 128), 0xbefe_0424,
        0xf800_180f,     0x0001_0100,     0xbf81_0000,     0xbefe_0480,
        0xf800_1800,     0,               0xbf81_0000,
    };

    const blue = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 242), 0xf800_180f, 0x0101_0000, 0xbf81_0000 };
    const red = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 242), 0xf800_180f, 0x0100_0001, 0xbf81_0000 };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
    for (blue, 0..) |word, i| guest.word(0xb00 + i * 4, word);
    for (red, 0..) |word, i| guest.word(0xc00 + i * 4, word);
    @memset(guest.bytes[0x10000..0x14000], 0xa5); // stale disabled Z allocation
    var state = gpu.State{};
    const vs = gpu.resources.ShaderStage.vertex.programRegisterBase();
    const ps = gpu.resources.ShaderStage.pixel.programRegisterBase();
    try state.writeRegister(.shader, vs, 7);
    try state.writeRegister(.shader, vs + 1, 0);
    try state.writeRegister(.shader, ps, 9);
    try state.writeRegister(.shader, ps + 1, 0);
    const context = [_][2]u32{
        .{ 0x318, 0x20 },            .{ 0x319, 7 },               .{ 0x31b, 0 },               .{ 0x31c, 10 << 2 },    .{ 0x31d, 0 },
        .{ 0x390, 0 },               .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },         .{ 0x08e, 0 },          .{ 0x00c, 0 },
        .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },         .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 },          .{ 0x204, 1 << 19 },
        .{ 0x205, 0 },               .{ 0x202, 0xcc0010 },        .{ 0x191, 0 },               .{ 0x000, 2 },          .{ 0x007, 63 | (63 << 16) },
        .{ 0x010, 0 },               .{ 0x011, 0x20000181 },      .{ 0x012, 0x100 },           .{ 0x014, 0 },          .{ 0x013, 0x80 },
        .{ 0x015, 0x80 },            .{ 0x200, 3 | (7 << 8) },    .{ 0x10b, 3 << 4 },          .{ 0x10c, 0x01ffff01 }, .{ 0x00a, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 32, 32, -32, 32, 1, 0 }, 0..) |value, i|
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
    const backend = renderer.dcbBackend(guest.interface());
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    const draw = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
    // Clear S8 independently, then push the mask with all color writes off.
    _ = try executor.execute(&draw);
    if (renderer.last_draw_error) |err| return err;
    try state.writeRegister(.context, 0x000, 0);
    _ = try executor.execute(&draw);
    if (renderer.last_draw_error) |err| return err;
    try state.writeRegister(.shader, ps, 0xb);
    try state.writeRegister(.context, 0x08e, 0xf);
    try state.writeRegister(.context, 0x200, 3 | (2 << 8)); // stencil EQUAL; Z is disabled by its format
    try state.writeRegister(.context, 0x10b, 0);
    _ = try executor.execute(&draw);
    if (renderer.last_draw_error) |err| return err;
    try renderer.flushPendingGuestWrites();
    const left = 0x2000 + (32 * 64 + 24) * 4;
    const right = 0x2000 + (32 * 64 + 40) * 4;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, guest.bytes[left..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, guest.bytes[right..][0..4], .little));
    // The pop draw must remove the mask without erasing the UI's colors.
    try state.writeRegister(.context, 0x08e, 0);
    try state.writeRegister(.context, 0x200, 3 | (7 << 8));
    try state.writeRegister(.context, 0x10b, 3 << 4);
    try state.writeRegister(.context, 0x10c, 0x00ffff00);
    _ = try executor.execute(&draw);
    if (renderer.last_draw_error) |err| return err;
    try state.writeRegister(.shader, ps, 0xc);
    try state.writeRegister(.context, 0x08e, 0xf);
    try state.writeRegister(.context, 0x200, 3 | (2 << 8));
    try state.writeRegister(.context, 0x10b, 0);
    try state.writeRegister(.context, 0x10c, 0x01ffff01);
    _ = try executor.execute(&draw);
    if (renderer.last_draw_error) |err| return err;
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, guest.bytes[left..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, guest.bytes[right..][0..4], .little));
    try std.testing.expect(std.mem.allEqual(u8, guest.bytes[0x10000..0x14000], 0xa5));
    std.debug.print("Stencil-only UI passed: masked push/pop, clipped color, S8 transfers and untouched disabled Z\n", .{});

    const replacements = [_]struct { compare: u32, reference: u8, compare_mask: u8, write_mask: u8, op_value: u8, operation: u32, result: u8 }{
        .{ .compare = 7, .reference = 0, .compare_mask = 0xff, .write_mask = 0xff, .op_value = 0x48, .operation = 4, .result = 0x48 },
        .{ .compare = 2, .reference = 8, .compare_mask = 0x0f, .write_mask = 0xf0, .op_value = 0x88, .operation = 4, .result = 0x88 },
        .{ .compare = 1, .reference = 7, .compare_mask = 0x0f, .write_mask = 0xf0, .op_value = 0x27, .operation = 4, .result = 0x28 },
        .{ .compare = 7, .reference = 0x11, .compare_mask = 0xff, .write_mask = 0xff, .op_value = 0xaa, .operation = 3, .result = 0x11 },
    };
    for (replacements, 0..) |replacement, pass| {
        try state.writeRegister(.shader, ps, 9); // same clipped stencil geometry
        try state.writeRegister(.context, 0x08e, 0);
        try state.writeRegister(.context, 0x200, 3 | (replacement.compare << 8) | (replacement.compare << 20) | (1 << 7));
        try state.writeRegister(.context, 0x10b, (replacement.operation << 4) | (replacement.operation << 16));
        const mask: u32 = @as(u32, replacement.reference) | (@as(u32, replacement.compare_mask) << 8) |
            (@as(u32, replacement.write_mask) << 16) | (@as(u32, replacement.op_value) << 24);
        try state.writeRegister(.context, 0x10c, mask);
        try state.writeRegister(.context, 0x10d, mask);
        _ = try executor.execute(&draw);
        if (renderer.last_draw_error) |err| return err;
        try state.writeRegister(.shader, ps, if (pass % 2 == 0) 0xc else 0xb);
        try state.writeRegister(.context, 0x08e, 0xf);
        try state.writeRegister(.context, 0x200, 3 | (2 << 8));
        try state.writeRegister(.context, 0x10b, 0);
        try state.writeRegister(.context, 0x10c, 0x00ffff00 | @as(u32, replacement.result));
        _ = try executor.execute(&draw);
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, guest.bytes[left..][0..4], .little));
        try std.testing.expectEqual(@as(u32, if (pass % 2 == 0) 0xff0000ff else 0xffff0000), std.mem.readInt(u32, guest.bytes[right..][0..4], .little));
    }
    std.debug.print("stencil operation values passed: distinct REPLACE_OP/TEST, masked EQUAL/LESS, both face states and subsequent stencil consumers\n", .{});
}

fn runIndirectDispatchProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    const guest = try allocator.create(SizedGuestMemory(524288));
    defer allocator.destroy(guest);
    guest.* = .{};
    const backend = renderer.dcbBackend(guest.interface());
    const arguments = 0x10000;
    const output = 0x60000;
    const producer_program = 0x1400;
    const consumer_program = 0x1800;
    const producer_code = [_]u32{
        vop1(1, 0, 128),            vop1(1, 1, 4),              vop1(1, 2, 129),
        mubuf(0x1c, 0, 1, 0, 0)[0], mubuf(0x1c, 0, 1, 0, 0)[1], mubuf(0x1c, 4, 2, 0, 0)[0],
        mubuf(0x1c, 4, 2, 0, 0)[1], mubuf(0x1c, 8, 2, 0, 0)[0], mubuf(0x1c, 8, 2, 0, 0)[1],
        0xbf81_0000,
    };
    const consumer_code = [_]u32{
        vop1(1, 0, 4), // Workgroup X follows the four user SGPRs.
        vop1(1, 1, 135),
        mubuf(0x1c, 0, 1, 0, 0)[0],
        mubuf(0x1c, 0, 1, 0, 0)[1],
        0xbf81_0000,
    };
    for (producer_code, 0..) |word, i| guest.word(producer_program + i * 4, word);
    for (consumer_code, 0..) |word, i| guest.word(consumer_program + i * 4, word);
    var producer = gpu.State{};
    var consumer = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    for ([_]*gpu.State{ &producer, &consumer }, 0..) |state, i| {
        try state.writeRegister(.shader, compute.programRegisterBase(), (if (i == 0) @as(u32, producer_program) else consumer_program) >> 8);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, if (i == 0) 5 << 1 else (4 << 1) | (1 << 7));
        for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try state.writeRegister(.shader, reg, 1);
        // A large producer range keeps its GPU writes deferred until the
        // indirect command requests these twelve argument bytes.
        const descriptor = if (i == 0) [_]u32{ arguments, 4 << 16, 65536, 0 } else [_]u32{ output, 4 << 16, 16, 0 };
        for (descriptor, 0..) |word, n| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(n)), word);
    }
    var writer = gpu.DcbExecutor{ .state = &producer, .backend = backend, .allocator = allocator };
    var reader = gpu.DcbExecutor{ .state = &consumer, .backend = backend, .allocator = allocator };
    const direct = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    const relative = [_]u32{
        command(gpu.pm4.set_base, 3) | 2,      1,    arguments - 0x20, 0,
        command(gpu.pm4.dispatch_indirect, 2), 0x20, 0x41,
    };
    const absolute = [_]u32{ command(gpu.pm4.dispatch_indirect, 3), arguments, 0, 0x41 };
    for ([_]bool{ false, true }) |absolute_address| {
        for ([_]u32{ 3, 0, 5 }) |count| {
            @memset(guest.bytes[output..][0..64], 0xcd);
            try producer.writeRegister(.shader, compute.userDataBase() + 4, count);
            const previous_count = std.mem.readInt(u32, guest.bytes[arguments..][0..4], .little);
            _ = try writer.execute(&direct);
            try std.testing.expectEqual(previous_count, std.mem.readInt(u32, guest.bytes[arguments..][0..4], .little));
            if (absolute_address) {
                // ACB scene work copies counters through GDS before issuing
                // the indirect dispatch. Destroy the memory copy in between
                // so ignoring either DMA transfer cannot pass this check.
                const counters = [_]u32{
                    command(gpu.pm4.dma_data, 6), (3 << 29) | (1 << 20), arguments, 0, 0x100,     0, 12 | (1 << 31),
                    command(gpu.pm4.dma_data, 6), (2 << 29) | (3 << 20), 0,         0, arguments, 0, 12 | (1 << 31),
                    command(gpu.pm4.dma_data, 6), (1 << 29) | (3 << 20), 0x100,     0, arguments, 0, 12 | (1 << 31),
                };
                _ = try writer.execute(&counters);
            }
            _ = try reader.execute(if (absolute_address) &absolute else &relative);
            try renderer.flushPendingGuestWrites();
            try std.testing.expectEqual(count, std.mem.readInt(u32, guest.bytes[arguments..][0..4], .little));
            for (0..16) |lane| {
                const expected: u32 = if (lane < count) 7 else 0xcdcd_cdcd;
                try std.testing.expectEqual(expected, std.mem.readInt(u32, guest.bytes[output + lane * 4 ..][0..4], .little));
            }
        }
    }
    std.debug.print("indirect dispatch passed: GPU-produced dimensions, GDS counter transfers, relative/absolute addresses, nonzero offsets, zero work and changing counts\n", .{});
}

fn runUiAttachmentProbe(allocator: std.mem.Allocator) !void {
    for (0..8) |case| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        var vertex = [_]u32{
            vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
            vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
            vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
            0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
            0xf800_08cf,     0x0807_0605,      0xbf81_0000,
        };
        if (case >= 5) vertex[14] = vop1(1, 7, 241); // negative clip Z
        const fragment = [_]u32{ vop1(1, 0, 242), vop1(1, 1, 128), 0xf800_080f, 0x0001_0100, 0xbf81_0000 };
        for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), 7);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), 9);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase() + 1, 0);
        const htile = case >= 2 and case < 5;
        const disable_color = case == 1 or case == 4;
        // Jurassic's stale reset binding has no HTILE. The HTILE cases
        // model Yotei's active depth surface and must retain depth tests.
        const context = [_][2]u32{
            .{ 0x318, 0x20 },            .{ 0x319, 7 },               .{ 0x31b, 0 },               .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
            .{ 0x390, 0 },               .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },         .{ 0x08e, 0xf },     .{ 0x00c, 0 },
            .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },         .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 },       .{ 0x205, 0 },
            .{ 0x000, 0 },               .{ 0x007, 0 },               .{ 0x012, 0x80 },            .{ 0x014, 0x80 },    .{ 0x01a, 0 },
            .{ 0x01c, 0 },               .{ 0x01e, 0 },               .{ 0x011, 1 << 29 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        try state.writeRegister(.context, 0x010, 0x183 | (if (htile) @as(u32, 1) << 29 else 0));
        try state.writeRegister(.context, 0x005, if (htile) 0x1c0 else 0);
        try state.writeRegister(.context, 0x200, 6 | (if (case == 3) @as(u32, 6) << 4 else @as(u32, 1) << 4));
        if (case != 5) try state.writeRegister(.context, 0x204, if (case == 6) 1 << 19 else 0);
        // Leave CB_COLOR_CONTROL absent in case zero, as in Jurassic.
        try state.writeRegister(.context, 0x00b, 0); // initial depth = 0
        if (case != 0) try state.writeRegister(.context, 0x202, 0xcc0000 | (if (disable_color) @as(u32, 0) else 0x10));
        for ([_]f32{ 32, 32, -32, 32, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        const expected: u32 = if (case == 0 or case == 3 or case == 5 or case == 7) 0xff0000ff else 0;
        const center = 0x2000 + (32 * 64 + 32) * 4;
        const actual = std.mem.readInt(u32, guest.bytes[center..][0..4], .little);
        if (actual != expected) std.debug.print("UI attachment case={d}: expected={x} actual={x}\n", .{ case, expected, actual });
        try std.testing.expectEqual(expected, actual);
        try std.testing.expectEqual(@as(usize, if (htile) 1 else 0), renderer.depth_targets.items.len);
        if (htile) {
            try std.testing.expectEqual(@as(u32, 64), renderer.depth_targets.items[0].target.width);
            try std.testing.expectEqual(@as(u32, 64), renderer.depth_targets.items[0].target.height);
        }
    }
    std.debug.print("UI attachments passed: missing color/clip defaults, explicit disable/DX clip, stale depth and HTILE comparisons\n", .{});
}

fn runFragmentFirstActiveLaneProbe(allocator: std.mem.Allocator, scan_mask: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const vertex = [_]u32{
        0x34020a81,      0x36040a82, 0x36020282, 0x7e040d02, 0x7e060d01,
        0xd5410001,      0x03ce04f4, 0xd5410002, 0x03ce06f4, vop1(1, 0, 242),
        vop1(1, 3, 240), 0xf80008cf, 0x00030102, 0xbf810000,
    };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, program| {
        try state.writeRegister(.shader, stage.programRegisterBase(), program);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    const context = [_][2]u32{
        .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
        .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
        .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
        .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },             .{ 0x1b3, 0xf02 },   .{ 0x1b4, 0xf02 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 4, 4, -4, 4, 1, 0 }, 0..) |value, i|
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    for (0..@as(usize, if (scan_mask) 4 else 1)) |mode| for ([_]u9{ 129, 128, 129 }) |selected| {
        var fragment = std.ArrayList(u32).empty;
        defer fragment.deinit(allocator);
        try fragment.appendSlice(allocator, &.{
            vop1(7, 6, 258), vop2Source(0x1b, 6, 129, 6), // pixel X parity
            sop1(4, 20, 126), // preserve full EXEC
            0x7c000000 | (0xc2 << 17) | (6 << 9) | @as(u32, selected), // CMP_EQ_U32
            sop1(0x24, 22, 106), // select alternating columns in EXEC
        });
        if (scan_mask) {
            try fragment.append(allocator, sop1(4, 24, 126)); // copy EXEC to a saved scalar mask
            if (mode == 1) try fragment.append(allocator, 0x87808000 | (24 << 16) | 24); // saved &= 0
            if (mode == 2) {
                // Reusing a saved-mask SGPR for an integer must discard its
                // mask provenance, including a partial pair overwrite.
                try fragment.append(allocator, sop1(3, 24, 144)); // low=16; high retains saved mask
            }
            if (mode == 3) try fragment.append(allocator, sop1(3, 30, 128));
            const loop_start = fragment.items.len;
            try fragment.append(allocator, sop1(0x14, 12, 24)); // FF1 s12, saved mask
            if (mode == 1 or mode == 2) {
                const expected_bit: u32 = if (mode == 1) 193 else 132; // -1 or 4
                try fragment.append(allocator, 0xbf060000 | (expected_bit << 8) | 12);
                try fragment.append(allocator, 0x850c8081); // s12 = (scan == expected) ? 1 : 0
            } else try fragment.appendSlice(allocator, &.{ 0xd760000c, 262 | (12 << 9) }); // READLANE s12, v6, s12
            if (mode == 3) {
                try fragment.appendSlice(allocator, &.{
                    0x87987e18, // saved &= EXEC on the back edge
                    0x801e811e, // counter++
                    0xbf06821e, // counter == 2
                });
                const branch: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(fragment.items.len)) - 1;
                try fragment.append(allocator, 0xbf840000 | @as(u32, @as(u16, @bitCast(@as(i16, @intCast(branch))))));
            }
        } else try fragment.append(allocator, vop1(2, 12, 262));
        try fragment.appendSlice(allocator, &.{
            sop1(4, 126, 20), // restore all pixels before displaying the result
            vop1(6, 0, 12),
            vop1(1, 1, 128),
            vop1(1, 2, 242),
            0xf800180f,
            0x02010100,
            0xbf810000,
        });
        for (fragment.items, 0..) |word, i| guest.word(0x900 + i * 4, word);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (0..64) |pixel| {
            const actual = std.mem.readInt(u32, guest.bytes[0x2000 + pixel * 4 ..][0..4], .little);
            const expected: u32 = if (mode == 1 or mode == 2 or selected == 129) 0xff0000ff else 0xff000000;
            if (actual != expected) {
                std.debug.print("Fragment first-active mismatch mode={d} selection={d} pixel={d}: expected=0x{x} actual=0x{x}\n", .{ mode, selected - 128, pixel, expected, actual });
                return error.FragmentFirstActiveLaneMismatch;
            }
        }
    };
    std.debug.print("Fragment first active lane passed: alternating masks, saved-mask scans, empty masks, integer overwrites and loop back edges\n", .{});
}

fn runFragmentPositionProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    // A covering triangle with clip W=1, 2 or 4 and Z=.5. SPI supplies
    // window-space XY and clip W, unlike Vulkan FragCoord.w=1/W.
    const vertex = [_]u32{
        0x34020a81,       0x36040a82,       0x36020282,      0x7e040d02, 0x7e060d01,
        0xd5410001,       0x03ce04f4,       0xd5410002,      0x03ce06f4, vop1(1, 0, 244),
        vop2(8, 1, 1, 0), vop2(8, 2, 2, 0), vop1(1, 3, 240), 0xf80008cf, 0x00030102,
        0xbf810000,
    };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, program| {
        try state.writeRegister(.shader, stage.programRegisterBase(), program);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    const context = [_][2]u32{
        .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
        .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
        .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
        .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    const Case = struct { allocated: u16, enabled: u16, first: u8 };
    const cases = [_]Case{
        .{ .allocated = 0xf02, .enabled = 0xf02, .first = 2 },
        .{ .allocated = 0xf8f, .enabled = 0xf02, .first = 10 },
        .{ .allocated = 0xf8f, .enabled = 0xb02, .first = 10 },
        .{ .allocated = 0xf8f, .enabled = 0x902, .first = 10 },
        .{ .allocated = 0xf02, .enabled = 0xf02, .first = 2 },
    };
    for ([_]u9{ 242, 244, 246 }, [_]f32{ 1, 2, 4 }) |clip_word, clip_w| for (0..4) |mode| for (cases, 0..) |case, case_index| {
        guest.word(0x700 + 9 * 4, vop1(1, 0, clip_word));
        const negative = mode & 1 != 0;
        const zero_to_one = mode & 2 != 0;
        const first: u9 = 256 + @as(u9, case.first);
        const fragment = [_]u32{
            // Preserve entry VGPRs across a loop before reading position.
            0xbe940380,                0x80148114,              0xbf0a8214,                   0xbf85fffd,
            // A masked write joins the original entry value on the other
            // half. Both incoming register values must have the same type.
            vop1(1, 28, 246),          0xbe96047e,              0x7c223800 | @as(u32, first), 0xbf880002,
            vop1(1, case.first, 255),  @bitCast(@as(f32, 1.5)), 0xbefe0416,                   vop1(1, 24, first),
            vop1(1, 25, first + 1),    vop1(1, 26, first + 2),  vop1(1, 27, first + 3),       vop1(1, 28, 255),
            @bitCast(@as(f32, 0.125)), vop2(8, 24, 24, 28),     vop2(8, 25, 25, 28),          vop2(8, 27, 27, 28),
            0xf800180f,                0x1b1a1918,              0xbf810000,
        };
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        try state.writeRegister(.context, 0x1b4, case.allocated);
        try state.writeRegister(.context, 0x1b3, case.enabled);
        try state.writeRegister(.context, 0x204, if (zero_to_one) 1 << 19 else 0);
        for ([_]f32{ 4, 4, if (negative) -4 else 4, 4, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (0..8) |y| for (0..8) |x| {
            const expected = [_]u8{
                if (x < 4) 48 else @intCast((x * 2 + 1) * 255 / 16),
                if (case.enabled & 0x200 != 0) @intCast((y * 2 + 1) * 255 / 16) else 0,
                if (case.enabled & 0x400 != 0) @intFromFloat((if (zero_to_one) 0.5 / clip_w else 0.5 + 0.25 / clip_w) * 255) else 0,
                @intFromFloat(clip_w * 255 / 8),
            };
            for (expected, guest.bytes[0x2000 + (y * 8 + x) * 4 ..][0..4], 0..) |want, actual, channel| {
                if (@abs(@as(i16, actual) - want) > 1) {
                    std.debug.print("fragment position case={d} negative={any} xy={d},{d} channel={d}: expected={d} actual={d}\n", .{ case_index, negative, x, y, channel, want, actual });
                    return error.FragmentPositionMismatch;
                }
            }
        };
    };
    std.debug.print("Fragment position inputs preserve allocation holes, viewport orientation, depth and clip W\n", .{});
}

fn runFragmentFaceProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    // A covering triangle used in both winding orders and viewport signs.
    const vertex = [_]u32{
        0x34020a81,       0x36040a82,       0x36020282,      0x7e040d02, 0x7e060d01,
        0xd5410001,       0x03ce04f4,       0xd5410002,      0x03ce06f4, vop1(1, 0, 244),
        vop2(8, 1, 1, 0), vop2(8, 2, 2, 0), vop1(1, 3, 240), 0xf80008cf, 0x00030102,
        0xbf810000,
    };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, program| {
        try state.writeRegister(.shader, stage.programRegisterBase(), program);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    const context = [_][2]u32{
        .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
        .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
        .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
        .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    const Case = struct { allocated: u16, enabled: u16, face: u8 };
    const cases = [_]Case{
        .{ .allocated = 0x1302, .enabled = 0x1302, .face = 4 },
        .{ .allocated = 0x1f8f, .enabled = 0x1302, .face = 14 },
        .{ .allocated = 0x1f8f, .enabled = 0x0302, .face = 14 },
    };
    for (0..16) |mode| for (cases, 0..) |case, case_index| {
        const negative = mode & 1 != 0;
        const clockwise = mode & 2 != 0;
        const reverse = mode & 4 != 0;
        const all_bits = mode & 8 != 0;
        const first: u9 = 256 + @as(u9, case.face);
        // Same geometry, reversed index order, so both faces are observable.
        guest.word(0x700 + 14 * 4, if (reverse) 0x00030201 else 0x00030102);
        const fragment = [_]u32{
            // Preserve the system value through a loop before exporting it.
            0xbe940380,                              0x80148114, 0xbf0a8214, 0xbf85fffd,
            vop1(if (all_bits) 6 else 1, 24, first),
            vop1(1, 25, 240), // .5
            if (all_bits) vop1(1, 24, 280) else vop2(8, 24, 24, 25),
            if (all_bits) vop1(1, 24, 280) else vop2(3, 24, 24, 25),
            vop1(1, 25, 242),
            vop1(1, 26, 128),
            vop1(1, 27, 242),
            0xf800180f,
            0x1b1a1918,
            0xbf810000,
        };
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        try state.writeRegister(.context, 0x1b4, case.allocated);
        try state.writeRegister(.context, 0x1b3, case.enabled);
        try state.writeRegister(.context, 0x1b8, if (all_bits) 1 << 24 else 0);
        try state.writeRegister(.context, 0x205, if (clockwise) 1 << 2 else 0);
        for ([_]f32{ 4, 4, if (negative) -4 else 4, 4, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        // POS vertices are (-2,-2), (6,-2), (-2,6). Vulkan's framebuffer
        // signed area is negative for this order with a positive viewport.
        const front = (clockwise != negative) != reverse;
        const expected: u8 = if (case.enabled & 0x1000 == 0) (if (all_bits) @as(u8, 0) else 128) else if (front) 255 else 0;
        for (0..8) |y| for (0..8) |x| {
            const pixel = guest.bytes[0x2000 + (y * 8 + x) * 4 ..][0..4];
            if (@abs(@as(i16, pixel[0]) - expected) > 1 or pixel[1] != 255 or pixel[2] != 0 or pixel[3] != 255) {
                std.debug.print("fragment face case={d} mode={d} xy={d},{d}: expected={d} actual={any}\n", .{ case_index, mode, x, y, expected, pixel.* });
                return error.FragmentFaceMismatch;
            }
        };
    };
    std.debug.print("Fragment face inputs preserve allocation holes, disabled inputs, signed/integer encodings, winding and viewport orientation\n", .{});
}

fn runGuestCullingProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |honor| for (0..4) |cull| for (0..8) |mode| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        renderer.honor_guest_culling = honor;
        var guest = GuestMemory{};
        // A covering triangle used in both winding orders and viewport signs.
        const vertex = [_]u32{
            0x34020a81,       0x36040a82,       0x36020282,      0x7e040d02, 0x7e060d01,
            0xd5410001,       0x03ce04f4,       0xd5410002,      0x03ce06f4, vop1(1, 0, 244),
            vop2(8, 1, 1, 0), vop2(8, 2, 2, 0), vop1(1, 3, 240), 0xf80008cf, 0x00030102,
            0xbf810000,
        };
        for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
        var state = gpu.State{};
        for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, program| {
            try state.writeRegister(.shader, stage.programRegisterBase(), program);
            try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        }
        const context = [_][2]u32{
            .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
            .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
            .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
            .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        const case = .{ .allocated = @as(u16, 0x1302), .enabled = @as(u16, 0x1302), .face = @as(u8, 4) };
        const case_index = cull;
        const negative = mode & 1 != 0;
        const clockwise = mode & 2 != 0;
        const reverse = mode & 4 != 0;
        const all_bits = true;
        const first: u9 = 256 + @as(u9, case.face);
        // Same geometry, reversed index order, so both faces are observable.
        guest.word(0x700 + 14 * 4, if (reverse) 0x00030201 else 0x00030102);
        const fragment = [_]u32{
            // Preserve the system value through a loop before exporting it.
            0xbe940380,                              0x80148114, 0xbf0a8214, 0xbf85fffd,
            vop1(if (all_bits) 6 else 1, 24, first),
            vop1(1, 25, 240), // .5
            if (all_bits) vop1(1, 24, 280) else vop2(8, 24, 24, 25),
            if (all_bits) vop1(1, 24, 280) else vop2(3, 24, 24, 25),
            vop1(1, 25, 242),
            vop1(1, 26, 128),
            vop1(1, 27, 242),
            0xf800180f,
            0x1b1a1918,
            0xbf810000,
        };
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        try state.writeRegister(.context, 0x1b4, case.allocated);
        try state.writeRegister(.context, 0x1b3, case.enabled);
        try state.writeRegister(.context, 0x1b8, if (all_bits) 1 << 24 else 0);
        try state.writeRegister(.context, 0x205, @as(u32, @intCast(cull)) | (if (clockwise) @as(u32, 1) << 2 else 0));
        for ([_]f32{ 4, 4, if (negative) -4 else 4, 4, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        // Same signed-area oracle as the face-input probe, independent of
        // the backend's conversion of the guest FACE register.
        const front = (clockwise != negative) != reverse;
        const culled = honor and cull & (if (front) @as(usize, 1) else 2) != 0;
        const expected: u8 = if (!culled and front) 255 else 0;
        for (0..8) |y| for (0..8) |x| {
            const pixel = guest.bytes[0x2000 + (y * 8 + x) * 4 ..][0..4];
            if (@abs(@as(i16, pixel[0]) - expected) > 1 or pixel[1] != (if (culled) @as(u8, 0) else 255) or pixel[2] != 0 or pixel[3] != (if (culled) @as(u8, 0) else 255)) {
                std.debug.print("guest culling case={d} mode={d} xy={d},{d}: expected={d} actual={any}\n", .{ case_index, mode, x, y, expected, pixel.* });
                return error.GuestCullingMismatch;
            }
        };
    };
    std.debug.print("Guest face culling passed: none/front/back/both, both windings and viewport signs, diagnostic opt-out\n", .{});
}

fn runFullscreenOrientationProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    // Procedural triangle: POS.y = 2*y-1, PARAM0.y = (1-y)*scale+bias.
    // A negative viewport therefore does not imply flipped texture rows.
    const vertex = [_]u32{ 0x34020a81, 0x36040a82, 0x7e0002f2, 0xf4280004, 0xfa000000, 0x36020282, 0x7e040d02, 0x7e060d01, 0xd5410001, 0x03ce04f4, 0x080804f2, 0xd5410002, 0x03ce06f4, 0xbf8cc07f, 0xd5410003, 0x00080103, 0xd5410004, 0x000c0304, 0xf80008cf, 0x00000102, 0xf8000203, 0x00000403, 0xbf810000 };
    const fragment = [_]u32{ 0xbfa00001, 0xbefc0310, 0xc8100000, 0xc8140100, 0xc8110001, 0xc8150101, 0xf0900f08, 0x00400004, 0xbf8c3f70, 0x5e000300, 0x5e020702, 0xf8001c0f, 0x00000100, 0xbf810000 };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
    const image = sampledImageDescriptorWords(0x8000, 8, 8);
    const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
    const surface = try layout.base();
    for (0..8) |y| for (0..8) |x| {
        guest.word(0x8000 + @as(usize, @intCast(try surface.sourceByteOffset(@intCast(x), @intCast(y), 0, 0))), 0xff110000 | (@as(u32, @intCast(x * 30)) << 8) | @as(u32, @intCast(10 + y * 30)));
    };
    var state = gpu.State{};
    const vertex_stage = gpu.resources.ShaderStage.vertex;
    const pixel_stage = gpu.resources.ShaderStage.pixel;
    try state.writeRegister(.shader, vertex_stage.programRegisterBase(), 7);
    try state.writeRegister(.shader, vertex_stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, vertex_stage.programRegisterBase() + 3, 12 << 1);
    try state.writeRegister(.shader, pixel_stage.programRegisterBase(), 9);
    try state.writeRegister(.shader, pixel_stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, pixel_stage.programRegisterBase() + 3, 12 << 1);
    for ([_]u32{ 0x12000, 0, 16, 0 }, 0..) |word, i|
        try state.writeRegister(.shader, vertex_stage.userDataBase() + 8 + @as(u32, @intCast(i)), word);
    for (image, 0..) |word, i| try state.writeRegister(.shader, pixel_stage.userDataBase() + @as(u32, @intCast(i)), word);
    for (0..4) |i| try state.writeRegister(.shader, pixel_stage.userDataBase() + 8 + @as(u32, @intCast(i)), 0);
    const context = [_][2]u32{
        .{ 0x319, 0 }, .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 },                 .{ 0x31d, 0 },
        .{ 0x390, 0 }, .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },                 .{ 0x08e, 0xf },
        .{ 0x00c, 0 }, .{ 0x00d, 8 | (8 << 16) }, .{ 0x094, 1 << 31 },                 .{ 0x095, 8 | (8 << 16) },
        .{ 0x1e0, 0 }, .{ 0x200, 0 },             .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },
        .{ 0x205, 0 }, .{ 0x191, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    const stream = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    for (0..8) |case| {
        // Repeat through a resident render target, as in a multipass UI.
        if (case == 4) for (sampledImageDescriptorWords(0x2000, 8, 8), 0..) |word, i|
            try state.writeRegister(.shader, pixel_stage.userDataBase() + @as(u32, @intCast(i)), word);
        const negative_viewport = case % 4 < 2;
        const reverse_uv = case % 2 != 0;
        const destination = 0x2000 + case * 0x400;
        try state.writeRegister(.context, 0x318, @intCast(destination >> 8));
        for ([_]f32{ 4, 4, if (negative_viewport) -4 else 4, 4, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        for ([_]f32{ 1, if (reverse_uv) -1 else 1, 0, if (reverse_uv) 1 else 0 }, 0..) |value, i|
            guest.word(0x12000 + i * 4, @bitCast(value));
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (0..8) |y| for (0..8) |x| {
            const source_y = if (negative_viewport != reverse_uv) y else 7 - y;
            const expected: u32 = 0xff110000 | (@as(u32, @intCast(x * 30)) << 8) | @as(u32, @intCast(10 + source_y * 30));
            const actual = std.mem.readInt(u32, guest.bytes[destination + (y * 8 + x) * 4 ..][0..4], .little);
            if (actual != expected) std.debug.print("fullscreen orientation case={d} pixel={d},{d}: expected={x} actual={x}\n", .{ case, x, y, expected, actual });
            try std.testing.expectEqual(expected, actual);
        };
        if (case == 6) {
            // A later stencil-only quad can keep this copy PS and source
            // bound. The indexed fullscreen shortcut must honor MASK=0.
            guest.word(0x13000, 0x00010000);
            guest.word(0x13004, 0x00000002);
            guest.word(0x13008, 0x00020001);
            try state.writeRegister(.context, 0x08e, 0);
            try state.writeRegister(.context, 0x200, 1);
            const masked = [_]u32{ command(gpu.pm4.draw_index_2, 5), 6, 0x13000, 0, 6, 0 };
            _ = try executor.execute(&masked);
            if (renderer.last_draw_error) |err| return err;
            try renderer.flushPendingGuestWrites();
            for (0..8) |y| for (0..8) |x| {
                const expected: u32 = 0xff110000 | (@as(u32, @intCast(x * 30)) << 8) | @as(u32, @intCast(10 + (7 - y) * 30));
                try std.testing.expectEqual(expected, std.mem.readInt(u32, guest.bytes[destination + (y * 8 + x) * 4 ..][0..4], .little));
            };
            try state.writeRegister(.context, 0x08e, 0xf);
            try state.writeRegister(.context, 0x200, 0);
        }
    }
    std.debug.print("fullscreen orientation passed: procedural triangle, both viewport signs, runtime UV scale/bias and guest-memory/resident sources and a masked fullscreen quad\n", .{});
}

fn runBufferTargetCoherenceProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |deferred| for ([_]u32{ 8, 256 }) |extent| {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .defer_small_storage_writes = deferred });
        defer renderer.deinit();
        var guest = SizedGuestMemory(512 * 1024){};
        const center = 0x2000 + (extent / 2 * extent + extent / 2) * 4;
        const vertex = [_]u32{
            vop1(6, 1, 261), vop1(1, 2, 255),  0x3f800000,       vop2(4, 3, 1, 2),
            vop1(1, 4, 255), 0x3f400000,       vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
            vop1(1, 7, 255), 0xbfc00000,       vop2(8, 6, 6, 7), vop1(1, 8, 255),
            0x3f400000,      vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
            0xf80008cf,      0x08070605,       0xbf810000,
        };
        const fragment = [_]u32{ vop1(1, 0, 242), vop1(1, 1, 128), vop1(1, 2, 128), vop1(1, 3, 242), 0xf800080f, 0x03020100, 0xbf810000 };
        const store = mubuf(0x1c, 0, 1, 0, 0);
        const fill = [_]u32{ 0xd7460000, 0x04010c05, vop1(1, 1, 4), store[0], store[1], 0xbf810000 };
        for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
        for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
        for (fill, 0..) |word, i| guest.word(0x100 + i * 4, word);
        var state = gpu.State{};
        for ([_]gpu.resources.ShaderStage{ .vertex, .pixel, .compute }, [_]u32{ 7, 9, 1 }) |stage, program| {
            try state.writeRegister(.shader, stage.programRegisterBase(), program);
            try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        }
        try state.writeRegister(.shader, 0x213, (5 << 1) | (1 << 7));
        const context = [_][2]u32{
            .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
            .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
            .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
            .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        try state.writeRegister(.context, 0x3b0, ((extent - 1) << 14) | (extent - 1));
        try state.writeRegister(.context, 0x00d, extent | (extent << 16));
        try state.writeRegister(.context, 0x095, extent | (extent << 16));
        const half_extent: f32 = @floatFromInt(extent / 2);
        for ([_]f32{ half_extent, half_extent, half_extent, half_extent, 1, 0 }, 0..) |value, i|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        const draw = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
        _ = try executor.execute(&draw);
        if (renderer.last_draw_error) |err| return err;
        // The compute fill overwrites an already resident attachment. The
        // following triangle must keep the new fill outside its coverage.
        for ([_]u32{ 0xff563412, 0xffab8967, 0xff563412 }) |color| {
            for ([_]u32{ 0x2000, 4 << 16, extent * extent, 0, color }, 0..) |word, i|
                try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
            _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ extent * extent / 64, 1, 1 });
            _ = try executor.execute(&draw);
            if (renderer.last_draw_error) |err| return err;
            try renderer.flushPendingGuestWrites();
            const actual = std.mem.readInt(u32, guest.bytes[0x2000..][0..4], .little);
            std.debug.print("buffer target coherence deferred={any} extent={d}: expected=0x{x} actual=0x{x}\n", .{ deferred, extent, color, actual });
            try std.testing.expectEqual(color, actual);
            try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.readInt(u32, guest.bytes[center..][0..4], .little));
        }
        // Leave a new green triangle only on the GPU, then write one pixel
        // through the same full-buffer view. The other invocations are
        // absent, so the untouched centre must come from that latest draw.
        guest.word(0x900, vop1(1, 0, 128));
        guest.word(0x904, vop1(1, 1, 242));
        _ = try executor.execute(&draw);
        if (renderer.last_draw_error) |err| return err;
        try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.readInt(u32, guest.bytes[center..][0..4], .little));
        try state.writeRegister(.shader, 0x244, 0xff765432);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0xff765432), std.mem.readInt(u32, guest.bytes[0x2000..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0xff00ff00), std.mem.readInt(u32, guest.bytes[center..][0..4], .little));
    };
    std.debug.print("buffer target coherence passed: eager/deferred fills survive attachment reuse, partial stores retain latest GPU pixels\n", .{});
}

fn runResidentTargetReuseProbe(allocator: std.mem.Allocator) !void {
    for ([_]usize{ 64, 128 }) |limit| try runResidentTargetReuseAtLimit(allocator, limit);
}

fn runResidentTargetReuseAtLimit(allocator: std.mem.Allocator, limit: usize) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .render_target_cache_limit = limit });
    defer renderer.deinit();
    var guest = SizedGuestMemory(256 * 1024){};
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
    for (0..limit) |i| {
        try state.writeRegister(.context, 0x318, @intCast((0x2000 + i * 0x400) >> 8));
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error) |err| return err;
    }
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqual(limit, renderer.render_targets.items.len);
    const original = renderer.render_targets.items[0].image.handle;
    // A second frame's working set must fit without any allocation misses,
    // including attachments beyond the old 64-entry ceiling.
    const misses = renderer.frame_profile.render_target_misses;
    for (0..limit) |i| {
        const handle = renderer.render_targets.items[i].image.handle;
        try state.writeRegister(.context, 0x318, @intCast((0x2000 + i * 0x400) >> 8));
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error) |err| return err;
        try std.testing.expectEqual(handle, renderer.render_targets.items[i].image.handle);
    }
    try std.testing.expectEqual(misses, renderer.frame_profile.render_target_misses);
    const descriptors = [_]u32{ 0x20, (56 << 20) | (3 << 30), 1 | (7 << 14), 0x9000_0fac, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (descriptors, 0..) |word, i|
        try state.writeRegister(.shader, pixel.userDataBase() + 4 + @as(u32, @intCast(i)), word);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 3, 16 << 1);
    try state.writeRegister(.shader, pixel.programRegisterBase(), 0xa);
    for (limit..limit + 4) |i| {
        const destination = 0x2000 + i * 0x400;
        try state.writeRegister(.context, 0x318, @intCast(destination >> 8));
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error) |err| return err;
        try std.testing.expectEqual(limit, renderer.render_targets.items.len);
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
    // Seed a previously used attachment again while its preceding draw is
    // queued. Upload and readback share a buffer in the resident path; compare
    // every pixel with the independent transient-buffer path, including pixels
    // outside the triangle that must retain their new CPU-authored values.
    const destination = 0x2000 + (limit + 3) * 0x400;
    const destination_index = for (renderer.render_targets.items, 0..) |target, index| {
        if (target.target.descriptor.address == destination) break index;
    } else return error.MissingReuseTarget;
    const transfer = renderer.render_targets.items[destination_index].readback.handle;
    var expected: [8 * 8 * 4]u8 = undefined;
    for ([_]bool{ false, true, true }, 0..) |reuse, pass| {
        renderer.reuse_color_target_transfer = reuse;
        for (0..2) |queued| {
            for (0..64) |pixel_index|
                guest.word(destination + pixel_index * 4, 0xff674523 + @as(u32, @intCast(pixel_index + queued)));
            renderer.render_targets.items[destination_index].initialized = false;
            _ = try executor.execute(&stream);
            if (renderer.last_draw_error) |err| return err;
        }
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(transfer, renderer.render_targets.items[destination_index].readback.handle);
        const actual = guest.bytes[destination..][0..expected.len];
        if (pass == 0) {
            @memcpy(&expected, actual);
            // A triangle must draw its centre and preserve the uncovered seed.
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, actual[(4 * 8 + 4) * 4 ..][0..4]);
            try std.testing.expect(!std.mem.eql(u8, actual[0..4], &.{ 255, 0, 0, 255 }));
        } else try std.testing.expectEqualSlices(u8, &expected, actual);
    }
    std.debug.print("resident target reuse passed: {d} entries, warm working set, full cache, sampled source, GPU readback, released pins, queued transfer-buffer reseeding\n", .{limit});
}

fn runQueuedBufferReuseProbe(allocator: std.mem.Allocator, use_waits: bool, retain: bool, device_budget: usize) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{
        .enable_timeline_scheduler = true,
        .storage_buffer_use_waits = use_waits,
        .retain_clean_storage_buffers = retain,
        .storage_buffer_cache_budget_bytes = 64 * 16,
        .device_storage_budget_bytes = device_budget,
    });
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
        renderer.current_descriptor_slot = 0;
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        // The normal runner reserves a fresh descriptor set for the next draw.
        renderer.current_descriptor_slot = 1;
        renderer.descriptor_set = renderer.descriptor_sets[1];
        guest.word(replacement, 0xaabb_ccdd);
        _ = try renderer.stageGuestStorageBufferAt(0, replacement, 16);
        var result: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &result);
        renderer.draw_batch_active = false;
        renderer.current_descriptor_slot = null;
        renderer.descriptor_set = renderer.descriptor_sets[0];
        const actual = std.mem.readInt(u32, result[0..4], .little);
        if (actual != 0x1122_3344) {
            std.debug.print("queued buffer read mismatch (recycle={any}): 0x{x}\n", .{ recycle, actual });
            return error.QueuedBufferInputOverwritten;
        }
    }
    // Updating an allocation that no queued command uses must not submit an
    // unrelated copy. The older global wait flushed that copy unconditionally.
    renderer.draw_batch_active = false;
    @memset(&renderer.active_storage_buffers, 0);
    guest.word(0x2000, 0x1122_3344);
    _ = try renderer.stageGuestStorageBufferAt(2, 0x2000, 16);
    guest.word(0x2100, 0x5566_7788);
    guest.word(0x2200, 0);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x2100, 16);
    _ = try renderer.stageGuestStorageBufferAt(1, 0x2200, 16);
    // Slot 2 was prepared but is absent from this command's descriptor snapshot.
    renderer.active_storage_buffers[2] = 0;
    renderer.draw_batch_active = true;
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    const pending_before = renderer.pending_command_buffers.items.len;
    const submitted_before = renderer.submitted_tick;
    try std.testing.expect(pending_before != 0);
    if (device_budget == 0) {
        // A host-visible buffer with no queued users can be read without
        // submitting the unrelated source/destination copy. This also covers
        // reads outside a rotating descriptor slot; no descriptor is updated.
        var ready_result: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x2000, &ready_result);
        try std.testing.expectEqual(@as(u32, 0x1122_3344), std.mem.readInt(u32, ready_result[0..4], .little));
        if (use_waits) {
            try std.testing.expectEqual(submitted_before, renderer.submitted_tick);
            try std.testing.expectEqual(pending_before, renderer.pending_command_buffers.items.len);
        }
    }
    renderer.current_descriptor_slot = 1;
    renderer.descriptor_set = renderer.descriptor_sets[1];
    guest.word(0x2000, 0xdead_beef);
    _ = try renderer.stageGuestStorageBufferAt(2, 0x2000, 16);
    if (use_waits) {
        try std.testing.expectEqual(submitted_before, renderer.submitted_tick);
        try std.testing.expectEqual(pending_before + @as(usize, if (device_budget != 0) 1 else 0), renderer.pending_command_buffers.items.len);
    } else try std.testing.expect(renderer.submitted_tick > submitted_before);
    var independent_result: [16]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x2200, &independent_result);
    try std.testing.expectEqual(@as(u32, 0x5566_7788), std.mem.readInt(u32, independent_result[0..4], .little));
    renderer.draw_batch_active = false;
    renderer.current_descriptor_slot = null;
    renderer.descriptor_set = renderer.descriptor_sets[0];
    @memset(&renderer.active_storage_buffers, 0);
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

    const pipeline_count = renderer.compute_pipelines.items.len;
    for ([_]u32{ 0x2468_1357, 0x789a_bcde, 0xdead_beef, 0x7654_3210 }, 0..) |value, pass| {
        if (pass != 0) {
            // The pipeline outlives its translation-cache entry. Recreating
            // identical words must reuse it and release the old module owner.
            renderer.compute_translations.deinit(allocator);
            if (pass > 1) renderer.compute_translations.maximum_bytes = 0;
        }
        guest.word(large_source, value);
        const hits = renderer.pipeline_cache_hits;
        _ = try executor.execute(&stream);
        try std.testing.expectEqual(hits + 1, renderer.pipeline_cache_hits);
        try std.testing.expectEqual(pipeline_count, renderer.compute_pipelines.items.len);
        try renderer.readbackGuestStorageBuffer(large_destination, &rebound_result);
        try std.testing.expectEqual(value, std.mem.readInt(u32, rebound_result[0..4], .little));
    }
    std.debug.print("compute module lifetime passed: cached/uncached translations, eviction, pipeline reuse and changing input bytes\n", .{});
}

fn runDeviceStorageBudgetProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .device_storage_budget_bytes = 32 });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    try renderer.probeDeviceStoragePrefix(0x1000);
    for (1..4) |slot| _ = try renderer.stageGuestStorageBufferAt(@intCast(slot), 0x1000 + slot * 0x100, 16);
    var local_bytes: u64 = 0;
    for (renderer.guest_buffers.items) |entry| {
        if (entry.host_transfer != null) local_bytes += entry.device_local.size;
    }
    try std.testing.expectEqual(@as(u64, 32), local_bytes);
    // Recycle a local allocation into an odd byte view, then grow it beyond
    // the device budget. Both must use the direct CPU-visible backing.
    _ = try renderer.stageGuestStorageBufferAt(0, 0x2000, 15);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x2100, 64);
    for (renderer.guest_buffers.items) |entry| {
        if (entry.guest_address == 0x2100) try std.testing.expect(entry.host_transfer == null);
    }
    var bytes: [64]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x2100, &bytes);
    try std.testing.expectEqualSlices(u8, guest.bytes[0x2100..][0..64], &bytes);
    // Disabling the budget changes recycled backings without disturbing
    // still-bound descriptor aliases or losing their completed GPU writes.
    renderer.device_storage_budget_bytes = 0;
    _ = try renderer.stageGuestStorageBufferAt(1, 0x2200, 16);
    for (renderer.guest_buffers.items) |entry| {
        if (entry.guest_address == 0x2200) try std.testing.expect(entry.host_transfer == null);
    }
    std.debug.print("device storage transfers passed: partial GPU writeback, retained dirty suffix, budget, odd range, growth and opt-out recycling\n", .{});
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
        for (0..(try renderer.readbackGdsStorage()).len / 4) |index| {
            const expected: u32 = if (index == 0x108 / 4) case.expected else 0;
            try std.testing.expectEqual(expected, std.mem.readInt(u32, (try renderer.readbackGdsStorage())[index * 4 ..][0..4], .little));
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
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, (try renderer.readbackGdsStorage())[0x108..][0..4], .little));
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
        try std.testing.expectEqual(prefix_total, std.mem.readInt(u32, (try renderer.readbackGdsStorage())[0x120..][0..4], .little));
    }
    std.debug.print("GDS atomic passed: persistent counter, cross-workgroup updates, EXEC low/high, segment and physical bounds, returned value\n", .{});
}

fn runGdsWave64AppendProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0xbefc_0300, // M0 = s0: GDS base and size
        vop2Source(0x1b, 1, 129, 0), // v1 = lane & 1
        0x7da6_0001, // CMPX LE s1, v0: exclude lanes below the cutoff
        0x7da4_0280, // CMPX EQ 0, v1: keep only even lanes
        0xbe8c_107e, // s12 = popcount(EXEC), including both halves
        vop1(1, 5, 12),
        0xd8fa_0004, 0x0200_0000, // APPEND v2: one shared base for the wave
        0xd766_0003, 127 | (128 << 9), // MBCNT high(EXEC_HI, 0)
        0xd765_0003, 126 | (259 << 9), // MBCNT low(EXEC_LO, v3)
        0xd8f6_0004, 0x0400_0000, // CONSUME v4: returns base + active count
        0xe078_2000, 0x8001_0200, // Store [base, rank, consumed, count] at lane
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0, 35, 1, 64 }, 0..) |cutoff, case_index| {
        const destination: u32 = 0x10000 + @as(u32, @intCast(case_index)) * 0x1000;
        for (0..256) |word| guest.word(destination + word * 4, 0xcccc_cccc);
        for ([_]u32{ 0x0100_0008, cutoff, 0, 0, destination, 16 << 16, 64, 0 }, 0..) |word, index| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var output: [1024]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &output);
        const first = (cutoff + 1) & ~@as(u32, 1);
        const count = (64 - first) / 2;
        for (0..64) |lane| {
            const active = lane >= cutoff and lane % 2 == 0;
            const expected: [4]u32 = if (active) .{ 0, @intCast((lane - first) / 2), count, count } else @splat(0xcccc_cccc);
            for (expected, 0..) |word, component| {
                const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                if (actual != word) std.debug.print("GDS wave64 cutoff={d} lane={d} component={d}: expected={x} actual={x}\n", .{ cutoff, lane, component, word, actual });
                try std.testing.expectEqual(word, actual);
            }
        }
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, (try renderer.readbackGdsStorage())[0x104..][0..4], .little));
    }
    std.debug.print("GDS wave64 append passed: dynamic sparse masks, high-only/empty EXEC, compact ranks and shared append/consume return values\n", .{});
}

fn runGdsResidentProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0xbefc_0300, vop1(1, 1, 1), vop1(1, 2, 4),
        0xbefe_0402, 0xd802_0004,   0x0000_0102,
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 5 << 1);
    for ([_]u32{ 0x0100_0010, 1, 0, 0x100, 4 }, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    // Cross the descriptor ring boundary while one active high lane in each
    // workgroup updates the same counter. No CPU reads between dispatches.
    for (0..520) |index| {
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 3, 1, 1 });
        if (index == 9) try std.testing.expect(renderer.pending_command_buffers.items.len >= 10);
    }
    try std.testing.expect(renderer.gds_gpu_dirty);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, renderer.gds_storage.items[0x108..][0..4], .little));
    const dma = gpu.state.DmaData{
        .engine = 0,
        .source = 1,
        .source_cache_policy = 0,
        .source_address = 0x108,
        .destination = 0,
        .destination_cache_policy = 0,
        .destination_address = 0x18000,
        .byte_count = 8,
        .wait_for_previous = true,
        .write_confirm = true,
        .block_engine = true,
    };
    try std.testing.expect(backend.vtable.dma_data.?(backend.context, dma));
    try std.testing.expectEqual(@as(u32, 1560), std.mem.readInt(u32, guest.bytes[0x18000..][0..4], .little));
    try state.writeRegister(.shader, compute.userDataBase() + 1, 2);
    for (0..8) |_| _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 3, 1, 1 });
    var partial = dma;
    partial.source = 2;
    partial.source_address = 7;
    partial.destination = 1;
    partial.destination_address = 0x10c;
    partial.byte_count = 4;
    try std.testing.expect(backend.vtable.dma_data.?(backend.context, partial));
    try state.writeRegister(.shader, compute.userDataBase() + 1, 3);
    _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 3, 1, 1 });
    try std.testing.expect(backend.vtable.dma_data.?(backend.context, dma));
    try std.testing.expectEqual(@as(u32, 1617), std.mem.readInt(u32, guest.bytes[0x18000..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, guest.bytes[0x18004..][0..4], .little));
    guest.word(0x19000, 19);
    partial.source = 0;
    partial.source_address = 0x19000;
    partial.destination_address = 0x108;
    try std.testing.expect(backend.vtable.dma_data.?(backend.context, partial));
    _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 3, 1, 1 });
    try std.testing.expect(backend.vtable.dma_data.?(backend.context, dma));
    try std.testing.expectEqual(@as(u32, 28), std.mem.readInt(u32, guest.bytes[0x18000..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, guest.bytes[0x18004..][0..4], .little));
    renderer.retain_gds_on_gpu = false;
    _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 3, 1, 1 });
    try std.testing.expect(!renderer.gds_gpu_dirty);
    try std.testing.expectEqual(@as(u32, 37), std.mem.readInt(u32, (try renderer.readbackGdsStorage())[0x108..][0..4], .little));
    std.debug.print("resident GDS passed: 520 queued producers, descriptor reuse, DMA reads, partial CPU writes, resumed GPU atomics and synchronous mode\n", .{});
}

fn runGdsMemoryProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0xbefc_0300, // M0 = base / size
        vop1(1, 1, 1),
        vop1(1, 2, 4),
        vop1(1, 3, 5),
        0xbefe_0402, // EXEC = s2:s3, one writer or no writer
        0xd936_0004, 0x0000_0201, // ds_write_b64 v1, v2:v3 offset:4 gds
        0xbf81_0000,
    };
    const read_code = [_]u32{
        0xbefc_0300,
        vop1(1, 1, 6),
        0xd9da_0004, 0x0400_0001, // ds_read_b64 v4:v5, v1 offset:4 gds
        0xd8da_0004, 0x0400_0001, // same first word through ds_read_b32
        0xe074_2000, 0x8002_0400, // all lanes store the pair through V#s8
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    for (read_code, 0..) |word, index| guest.word(0x200 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 12 << 1);
    const Case = struct { m0: u32 = 0x0100_0010, address: u32 = 4, mask: u64 = 1, values: [2]u32 = .{ 11, 22 }, expected: [2]u32 };
    const cases = [_]Case{
        .{ .expected = .{ 11, 22 } },
        .{ .address = 8, .values = .{ 33, 44 }, .expected = .{ 33, 0 } }, // second word outside segment
        .{ .mask = 0, .values = .{ 99, 99 }, .expected = .{ 11, 33 } },
        .{ .address = 0xffff_fffc, .expected = .{ 0, 0 } }, // relative offset wraps
        .{ .m0 = 0xfffc_0010, .address = 0, .expected = .{ 0, 0 } }, // physical 64 KiB boundary
        .{ .m0 = 0x0100_0000, .expected = .{ 0, 0 } },
        .{ .m0 = 0x0200_0010, .mask = @as(u64, 1) << 40, .values = .{ 55, 66 }, .expected = .{ 55, 66 } },
    };
    var expected_gds: [64 * 1024]u8 = @splat(0);
    for (cases, 0..) |case, pass| {
        const destination: u32 = 0x18000 + @as(u32, @intCast(pass)) * 0x1000;
        const userdata = [_]u32{ case.m0, case.address, @truncate(case.mask), @truncate(case.mask >> 32), case.values[0], case.values[1], case.address, 0, destination, 8 << 16, 64, 0 };
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        try state.writeRegister(.shader, compute.programRegisterBase(), 1);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        try state.writeRegister(.shader, compute.programRegisterBase(), 2);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var output: [512]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &output);
        for (0..64) |lane| for (case.expected, 0..) |expected, component| {
            try std.testing.expectEqual(expected, std.mem.readInt(u32, output[lane * 8 + component * 4 ..][0..4], .little));
        };
        switch (pass) {
            0 => {
                std.mem.writeInt(u32, expected_gds[0x108..][0..4], 11, .little);
                std.mem.writeInt(u32, expected_gds[0x10c..][0..4], 22, .little);
            },
            1 => std.mem.writeInt(u32, expected_gds[0x10c..][0..4], 33, .little),
            6 => {
                std.mem.writeInt(u32, expected_gds[0x208..][0..4], 55, .little);
                std.mem.writeInt(u32, expected_gds[0x20c..][0..4], 66, .little);
            },
            else => {},
        }
        try std.testing.expectEqualSlices(u8, &expected_gds, (try renderer.readbackGdsStorage()));
    }
    std.debug.print("GDS memory passed: persistent word pairs, low/high EXEC, per-word segment bounds, address wrap and physical bounds\n", .{});
}

fn runIntegerFormatStoreProbe(allocator: std.mem.Allocator) !void {
    var guest = GuestMemory{};
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    _ = renderer.dcbBackend(guest.interface());
    const cases = [_]struct { format: u32, width: u8, components: u8 }{
        .{ .format = 5, .width = 1, .components = 1 }, // R8_UINT
        .{ .format = 18, .width = 1, .components = 2 }, // R8G8_UINT
        .{ .format = 60, .width = 1, .components = 4 }, // R8G8B8A8_UINT light counts
        .{ .format = 6, .width = 1, .components = 1 },
        .{ .format = 19, .width = 1, .components = 2 },
        .{ .format = 61, .width = 1, .components = 4 },
        .{ .format = 11, .width = 2, .components = 1 }, // R16_UINT light indices
        .{ .format = 12, .width = 2, .components = 1 },
        .{ .format = 20, .width = 4, .components = 1 }, // unchanged R32_UINT
    };
    const stage = gpu.resources.ShaderStage.compute;
    for (cases, 0..) |case, case_index| {
        for ([_]bool{ false, true }, 0..) |inactive, phase| {
            const code_address: u32 = 0x100 + @as(u32, @intCast(case_index * 2 + phase)) * 0x100;
            const target: u32 = 0x4000 + @as(u32, @intCast(case_index * 2 + phase)) * 0x400;
            const stride: u32 = @as(u32, case.width) * case.components;
            const length: usize = 60 * stride;
            @memset(guest.bytes[target..][0..length], 0xa5);
            var code: std.ArrayList(u32) = .empty;
            defer code.deinit(allocator);
            const signed = case.format == 6 or case.format == 19 or case.format == 61 or case.format == 12;
            // Each lane has its own first component. The other components
            // distinguish a packed record from repeated scalar stores.
            try code.append(allocator, vop1(1, 1, 256));
            for ([_]u32{ if (signed) 0xffff_ffff else 7, if (signed) 0xffff_fffe else 11, if (signed) 0xffff_fffd else 13 }, 0..) |value, index| {
                try code.appendSlice(allocator, &.{ vop1(1, @intCast(index + 2), 255), value });
            }
            if (inactive) try code.append(allocator, 0xbefe_0480); // EXEC = 0
            try code.appendSlice(allocator, &mubuf(@as(u7, 4) + @as(u7, @intCast(case.components - 1)), 0, 1, 0, 0));
            try code.append(allocator, 0xbf81_0000);
            for (code.items, 0..) |word, index| guest.word(code_address + index * 4, word);
            var state = gpu.State{};
            try state.writeRegister(.shader, stage.programRegisterBase(), code_address >> 8);
            try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
            try state.writeRegister(.shader, 0x213, 4 << 1);
            const descriptor = [_]u32{ target, stride << 16, 60, (case.format << 12) | 4 | (5 << 3) | (6 << 6) | (7 << 9) };
            for (descriptor, 0..) |word, index| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
            // Four extra lanes exercise the descriptor boundary. Sixty
            // adjacent records exercise byte/halfword sharing in one SSBO.
            _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
            var result: [240]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(target, result[0..length]);
            for (0..60) |lane| {
                const values = [_]u32{ @intCast(lane), if (signed) 0xffff_ffff else 7, if (signed) 0xffff_fffe else 11, if (signed) 0xffff_fffd else 13 };
                for (0..case.components) |component| for (0..case.width) |byte| {
                    const expected: u8 = if (inactive) 0xa5 else @truncate(values[component] >> @as(u5, @intCast(byte * 8)));
                    try std.testing.expectEqual(expected, result[lane * stride + component * case.width + byte]);
                };
            }
        }
    }
    std.debug.print("integer format stores passed: packed byte/halfword records, signed components, R32, EXEC and bounds\n", .{});
}

fn runPackedChannelOrderProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{ 0xe00c_0000, 0x8000_0400, 0xe078_0000, 0x8001_0400, 0xbf81_0000 };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    // Independent packed words, including a captured tree normal. The two
    // 10-bit layouts and both mini-float layouts must not exchange channels.
    const cases = [_]struct { format: u32, bits: u32, expected: [4]f32 }{
        // Yotei animation V#s use the GFX10 packed SNORM format omitted from
        // the public RDNA2 format table. X/Y have 11 bits and Z has 10 bits.
        .{ .format = 31, .bits = (511 << 22) | (2047 << 11) | 1024, .expected = .{ -1, -1.0 / 1023.0, 1, 1 } },
        .{ .format = 31, .bits = (512 << 22) | (1023 << 11) | 513, .expected = .{ 513.0 / 1023.0, 1, -1, 1 } },
        .{ .format = 31, .bits = (767 << 22) | (1535 << 11) | 2047, .expected = .{ -1.0 / 1023.0, -513.0 / 1023.0, -257.0 / 511.0, 1 } },
        .{ .format = 51, .bits = 0x3df8_74a2, .expected = .{ 162.0 / 511.0, -483.0 / 511.0, -33.0 / 511.0, 0 } },
        .{ .format = 51, .bits = (2 << 30) | (511 << 20) | (1023 << 10) | 512, .expected = .{ -1, -1.0 / 511.0, 1, -1 } },
        .{ .format = 50, .bits = (3 << 30) | (512 << 20) | (256 << 10) | 1023, .expected = .{ 1, 256.0 / 1023.0, 512.0 / 1023.0, 1 } },
        .{ .format = 45, .bits = (511 << 22) | (1023 << 12) | (512 << 2) | 2, .expected = .{ -1, -1, -1.0 / 511.0, 1 } },
        .{ .format = 44, .bits = (512 << 22) | (256 << 12) | (1023 << 2) | 3, .expected = .{ 1, 1, 256.0 / 1023.0, 512.0 / 1023.0 } },
        .{ .format = 36, .bits = (0x200 << 22) | (0x3c0 << 11) | 0x380, .expected = .{ 0.5, 1, 2, 1 } },
        .{ .format = 43, .bits = (0x400 << 21) | (0x3c0 << 10) | 0x1c0, .expected = .{ 0.5, 1, 2, 1 } },
    };
    for (cases, 0..) |case, index| {
        const source: u32 = 0x4000 + @as(u32, @intCast(index)) * 0x100;
        const destination = source + 0x1000;
        guest.word(source, case.bits);
        for ([_]u32{ source, 0, 4, (case.format << 12) | 4 | (5 << 3) | (6 << 6) | (7 << 9), destination, 0, 16, 0 }, 0..) |word, i|
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var output: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &output);
        for (case.expected, 0..) |expected, channel| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[channel * 4 ..][0..4], .little));
            if (@abs(expected - actual) > 0.00001) std.debug.print("packed format={d} channel={d} expected={d} actual={d}\n", .{ case.format, channel, expected, actual });
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
    }
    std.debug.print("Packed channel order passed: animation and tree SNORM, signed endpoints, UNORM and both mini-float layouts\n", .{});
}

fn runPackedBufferProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = SizedGuestMemory(256 * 1024){};
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
    // A fresh VGPR may receive its two halves in separate loads. Only the
    // loaded half is defined after the first instruction; both are defined
    // after the complementary load, which must preserve the first half.
    for (0..6) |index| {
        const opcode: u32 = @intCast(0x20 + index);
        const destination = ([_]u32{ 64, 65, 109, 127, 128, 255 })[index];
        const offset: u32 = if (index < 4) 1 else 3;
        const output: u32 = @intCast(28 + index * 8);
        try code.appendSlice(allocator, &.{
            0xe000_0000 | (opcode << 18) | offset,       0x8000_0000 | (destination << 8),
            0xe070_0000 | output,                        0x8001_0000 | (destination << 8),
            0xe000_0000 | ((opcode ^ 1) << 18) | offset, 0x8000_0000 | (destination << 8),
            0xe070_0000 | (output + 4),                  0x8001_0000 | (destination << 8),
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
    for ([_]u32{ 0x80, 0x80, 0xff80, 0xff80, 0x8001, 0x8001 }, 0..) |value, index| {
        const first = std.mem.readInt(u32, output[28 + index * 8 ..][0..4], .little);
        try std.testing.expectEqual(value, if (index % 2 == 0) first & 0xffff else first >> 16);
        try std.testing.expectEqual(value | (value << 16), std.mem.readInt(u32, output[32 + index * 8 ..][0..4], .little));
    }

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
    const store_formats = [_]struct { format: u32, count: u32, width: u32, high: bool = false }{
        .{ .format = 13, .count = 1, .width = 2 },
        .{ .format = 29, .count = 2, .width = 2 },
        .{ .format = 74, .count = 3, .width = 4 },
        .{ .format = 71, .count = 4, .width = 2 },
        .{ .format = 77, .count = 4, .width = 4 },
        .{ .format = 11, .count = 1, .width = 2, .high = true },
        .{ .format = 12, .count = 1, .width = 2, .high = true },
        .{ .format = 13, .count = 1, .width = 2, .high = true },
        .{ .format = 20, .count = 1, .width = 4, .high = true },
        .{ .format = 21, .count = 1, .width = 4, .high = true },
        .{ .format = 22, .count = 1, .width = 4, .high = true },
    };
    for (store_formats, 0..) |case, case_index| {
        const program: u32 = 7 + @as(u32, @intCast(case_index));
        const destination: u32 = 0x18000 + @as(u32, @intCast(case_index)) * 0x1000;
        const stride = case.count * case.width;
        const store_word: u32 = if (case.high) 0xe09c_6000 else 0xe200_2000 | ((0x83 + case.count) << 18);
        const store_code = [_]u32{
            vop1(1, 1, 255), 0xc000_3c00,
            vop1(1, 2, 255), 0x8000_3800,
            0x3606_009f, 0x7d7a_0680, // disable lanes 0 and 32
            store_word,  0x8001_0100,
            0xbefe_04c1, // restore EXEC; an OOB store must preserve word zero
            vop1(1, 0, 192), // index 64
            store_word,
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
                    const expected_half: u16 = if (lane % 32 == 0) (if (offset % 4 == 0) 0x5678 else 0x1234) else half_values[if (case.high) 1 else component];
                    try std.testing.expectEqual(expected_half, std.mem.readInt(u16, stored[offset..][0..2], .little));
                } else {
                    const expected_word: u32 = if (case.high) switch (case.format) {
                        20 => 0xc000,
                        21 => 0xffff_c000,
                        else => float_values[1],
                    } else float_values[component];
                    try std.testing.expectEqual(if (lane % 32 == 0) @as(u32, 0x1234_5678) else expected_word, std.mem.readInt(u32, stored[offset..][0..4], .little));
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

fn runPackedHalfClearProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .defer_small_storage_writes = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const vertex = [_]u32{
        vop1(6, 1, 261),  vop1(1, 2, 242), vop2(4, 3, 1, 2),
        vop1(1, 4, 255),  0x3f40_0000,     vop2(8, 5, 3, 4),
        vop2(8, 6, 3, 3), vop1(1, 7, 255), 0xbfc0_0000,
        vop2(8, 6, 6, 7), vop1(1, 8, 255), 0x3f40_0000,
        vop2(3, 6, 6, 8), vop1(1, 7, 128), vop1(1, 8, 242),
        0xf800_08cf,      0x0807_0605,     0xbf81_0000,
    };
    for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
    const fragment = [_]u32{ vop1(1, 0, 255), 0x3800_3400, vop1(1, 1, 255), 0x3c00_3a00, 0xf800_0c0f, 0x0100, 0xbf81_0000 };
    for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
    const clear = [_]u32{ 0xd746_0004, 0x0401_0c08, vop1(1, 0, 4), vop1(1, 1, 5), vop1(1, 2, 6), vop1(1, 3, 7), 0xe01c_2000, 0x8000_0004, 0xbf81_0000 };
    for (clear, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
        try state.writeRegister(.shader, stage.programRegisterBase(), address);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    const context = [_][2]u32{
        .{ 0x318, 0x20 },            .{ 0x319, 7 },                       .{ 0x31b, 0 },               .{ 0x31c, (12 << 2) | (7 << 8) },
        .{ 0x31d, 0 },               .{ 0x390, 0 },                       .{ 0x3a8, 0 },               .{ 0x3b0, (63 << 14) | 63 },
        .{ 0x3b8, 1 << 24 },         .{ 0x08e, 15 },                      .{ 0x1c5, 4 },               .{ 0x00c, 0 },
        .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },                 .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 },
        .{ 0x200, 0 },               .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },               .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, (8 << 1) | (1 << 7));
    for ([_]u32{ 0x2000, 16 << 16, 2048, (75 << 12) | 0xfac }, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    const patterns = [_][2]u32{ .{ 0, 0x3c00_0000 }, .{ 0xb400_3800, 0x4000_3a00 }, .{ 0x3c00_3c00, 0x3800_3400 } };
    for ([_]bool{ false, true }) |unbound| {
        for (patterns) |pattern| {
            try state.writeRegister(.context, 0x318, 0x20);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
            if (renderer.last_draw_error) |err| return err;
            // The preceding colour write stays GPU-resident. Neither its old
            // texels nor the clear should cross to the CPU before observation.
            if (unbound) try state.writeRegister(.context, 0x318, 0);
            for (0..4) |i| try state.writeRegister(.shader, 0x244 + @as(u32, @intCast(i)), pattern[i % 2]);
            const before = renderer.frame_profile.readback_bytes;
            const report = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 32, 1, 1 });
            try std.testing.expectEqual(@as(usize, 0), report.spirv_words);
            try std.testing.expectEqual(before, renderer.frame_profile.readback_bytes);
            try renderer.flushPendingGuestWrites();
            for (0..64 * 64) |pixel| for (pattern, 0..) |word, i| {
                try std.testing.expectEqual(word, std.mem.readInt(u32, guest.bytes[0x2000 + pixel * 8 + i * 4 ..][0..4], .little));
            };
        }
    }
    // A prefix fill must preserve all bytes outside the described allocation.
    var preserved: [64 * 64 * 8]u8 = undefined;
    @memcpy(&preserved, guest.bytes[0x2000..0xa000]);
    try state.writeRegister(.shader, 0x242, 1024);
    for (0..4) |i| try state.writeRegister(.shader, 0x244 + @as(u32, @intCast(i)), patterns[0][i % 2]);
    const partial = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 16, 1, 1 });
    try std.testing.expect(partial.spirv_words != 0);
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqualSlices(u8, preserved[16384..], guest.bytes[0x6000..0xa000]);
    for (0..2048) |pixel| try std.testing.expectEqual(@as(u64, 0x3c00_0000_0000_0000), std.mem.readInt(u64, guest.bytes[0x2000 + pixel * 8 ..][0..8], .little));
    // A full clear after a pending raw store must supersede that buffer too.
    _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 16, 1, 1 });
    try state.writeRegister(.shader, 0x242, 2048);
    for (0..4) |i| try state.writeRegister(.shader, 0x244 + @as(u32, @intCast(i)), patterns[1][i % 2]);
    const pending = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 32, 1, 1 });
    try std.testing.expect(pending.spirv_words != 0);
    try renderer.flushPendingGuestWrites();
    for (0..4096) |pixel| for (patterns[1], 0..) |word, i| {
        try std.testing.expectEqual(word, std.mem.readInt(u32, guest.bytes[0x2000 + pixel * 8 + i * 4 ..][0..4], .little));
    };
    std.debug.print("packed half clears passed: repeated RGBA16F patterns, active/unbound resident target, no clear readback, partial fill and pending buffer guard\n", .{});
}

fn runDccSingleClearProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const vertex = [_]u32{
        vop1(6, 1, 261),  vop1(1, 2, 242), vop2(4, 3, 1, 2),
        vop1(1, 4, 255),  0x3f40_0000,     vop2(8, 5, 3, 4),
        vop2(8, 6, 3, 3), vop1(1, 7, 255), 0xbfc0_0000,
        vop2(8, 6, 6, 7), vop1(1, 8, 255), 0x3f40_0000,
        vop2(3, 6, 6, 8), vop1(1, 7, 128), vop1(1, 8, 242),
        0xf800_08cf,      0x0807_0605,     0xbf81_0000,
    };
    for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
    const fragment = [_]u32{ vop1(1, 0, 255), 0x3800_3400, 0xf800_0c03, 0, 0xbf81_0000 };
    for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
    const clear = [_]u32{ 0xd746_0004, 0x0401_0c08, vop1(1, 0, 4), vop1(1, 1, 5), vop1(1, 2, 6), vop1(1, 3, 7), 0xe01c_2000, 0x8000_0004, 0xbf81_0000 };
    for (clear, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
        try state.writeRegister(.shader, stage.programRegisterBase(), address);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    const context = [_][2]u32{
        .{ 0x318, 0x20 },            .{ 0x319, 7 },               .{ 0x31b, 0 },                       .{ 0x31c, (5 << 2) | (7 << 8) | (1 << 28) },
        .{ 0x31d, 0 },               .{ 0x325, 0x80 },            .{ 0x390, 0 },                       .{ 0x3a8, 0 },
        .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },         .{ 0x08e, 3 },                       .{ 0x1c5, 4 },
        .{ 0x00c, 0 },               .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },                 .{ 0x095, 64 | (64 << 16) },
        .{ 0x1e0, 0 },               .{ 0x200, 0 },               .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },
        .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, (8 << 1) | (1 << 7));
    for ([_]u32{ 0x2000, 256 << 16, 64, (20 << 12) | 4, 0, 0, 0, 0 }, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    for ([_]u32{ 0x7e00_7e00, 0x3400_3800, 0x7c00_fc00 }) |value| {
        @memset(guest.bytes[0x8000..0x8040], 0xff);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0x3800_3400), std.mem.readInt(u32, guest.bytes[0x2000 + (32 * 64 + 32) * 4 ..][0..4], .little));
        // Each DCC byte covers 256 source bytes. The typed buffer kernel
        // writes only the representative texel, not a linear pixel fill.
        @memset(guest.bytes[0x8000..0x8040], 0x10);
        try state.writeRegister(.shader, 0x244, value);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        try renderer.flushPendingGuestWrites();
        for (0..64 * 64) |pixel| {
            const actual = std.mem.readInt(u32, guest.bytes[0x2000 + pixel * 4 ..][0..4], .little);
            if (value == 0x7e00_7e00) {
                try std.testing.expect(std.math.isNan(@as(f16, @bitCast(@as(u16, @truncate(actual))))));
                try std.testing.expect(std.math.isNan(@as(f16, @bitCast(@as(u16, @truncate(actual >> 16))))));
            } else try std.testing.expectEqual(value, actual);
        }
    }
    std.debug.print("DCC single-texel clears passed: resident RG16F, repeated rendering, finite values, NaNs and infinities\n", .{});
}

fn runDccMetadataClearProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const vertex = [_]u32{
        vop1(6, 1, 261),  vop1(1, 2, 242), vop2(4, 3, 1, 2),
        vop1(1, 4, 255),  0x3f40_0000,     vop2(8, 5, 3, 4),
        vop2(8, 6, 3, 3), vop1(1, 7, 255), 0xbfc0_0000,
        vop2(8, 6, 6, 7), vop1(1, 8, 255), 0x3f40_0000,
        vop2(3, 6, 6, 8), vop1(1, 7, 128), vop1(1, 8, 242),
        0xf800_08cf,      0x0807_0605,     0xbf81_0000,
    };
    for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
    const fragment = [_]u32{ vop1(1, 0, 255), 0x3800_3400, vop1(1, 1, 255), 0x3c00_3a00, 0xf800_0c0f, 0x0100, 0xbf81_0000 };
    for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
    const clear = [_]u32{ 0xd746_0004, 0x0401_0c08, vop1(1, 0, 4), vop1(1, 1, 5), vop1(1, 2, 6), vop1(1, 3, 7), 0xe01c_2000, 0x8000_0004, 0xbf81_0000 };
    for (clear, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
        try state.writeRegister(.shader, stage.programRegisterBase(), address);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    const context = [_][2]u32{
        .{ 0x318, 0x20 },            .{ 0x319, 7 },               .{ 0x31b, 0 },                       .{ 0x31c, (12 << 2) | (7 << 8) | (1 << 28) },
        .{ 0x31d, 0 },               .{ 0x325, 0x1c0 },           .{ 0x390, 0 },                       .{ 0x3a8, 0 },
        .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },         .{ 0x08e, 15 },                      .{ 0x1c5, 4 },
        .{ 0x00c, 0 },               .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },                 .{ 0x095, 64 | (64 << 16) },
        .{ 0x1e0, 0 },               .{ 0x200, 0 },               .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },
        .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, (8 << 1) | (1 << 7));
    for ([_]u32{ 0x1c000, 16 << 16, 64, (75 << 12) | 0xfac, 0, 0, 0, 0 }, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    for ([_]u32{ 0, 0x4040_4040, 0x8080_8080, 0xc0c0_c0c0, 0 }) |value| {
        @memset(guest.bytes[0x1c000..0x1c400], 0xff);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0x3800_3400), std.mem.readInt(u32, guest.bytes[0x2000 + (32 * 64 + 32) * 8 ..][0..4], .little));
        for (0..4) |word| try state.writeRegister(.shader, 0x244 + @as(u32, @intCast(word)), value);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        try renderer.flushPendingGuestWrites();
        for (0..64 * 64) |pixel| for (0..4) |channel| {
            const expected: u16 = if (value & (if (channel == 3) @as(u32, 0x40) else 0x80) != 0) 0x3c00 else 0;
            try std.testing.expectEqual(expected, std.mem.readInt(u16, guest.bytes[0x2000 + pixel * 8 + channel * 2 ..][0..2], .little));
        };
    }
    @memset(guest.bytes[0x1c000..0x1c400], 0xff);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    try renderer.flushPendingGuestWrites();
    var preserved: [64 * 64 * 8]u8 = undefined;
    @memcpy(&preserved, guest.bytes[0x2000..0xa000]);
    // Partial metadata, mixed keys and the uncompressed key must not clear
    // the whole attachment. Exercise the direct PM4 write path separately.
    try std.testing.expect(backend.vtable.write(backend.context, 0x1c000, &.{ 0, 0, 0, 0 }));
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqualSlices(u8, &preserved, guest.bytes[0x2000..0xa000]);
    var metadata: [1024]u8 = @splat(0xff);
    for ([_]bool{ true, false }) |mixed| {
        metadata[0] = if (mixed) 0 else 0xff;
        try std.testing.expect(backend.vtable.write(backend.context, 0x1c000, &metadata));
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqualSlices(u8, &preserved, guest.bytes[0x2000..0xa000]);
    }
    @memset(&metadata, 0x40);
    try std.testing.expect(backend.vtable.write(backend.context, 0x1c000, &metadata));
    try renderer.flushPendingGuestWrites();
    for (0..64 * 64) |pixel| try std.testing.expectEqual(@as(u64, 0x3c00_0000_0000_0000), std.mem.readInt(u64, guest.bytes[0x2000 + pixel * 8 ..][0..8], .little));
    try std.testing.expect(backend.vtable.dma_data.?(backend.context, .{
        .engine = 0,
        .source = 2,
        .source_cache_policy = 0,
        .destination = 0,
        .destination_cache_policy = 0,
        .source_address = 0xc0c0_c0c0,
        .destination_address = 0x1c000,
        .byte_count = 1024,
        .wait_for_previous = false,
        .write_confirm = true,
        .block_engine = false,
    }));
    try renderer.flushPendingGuestWrites();
    for (0..64 * 64) |pixel| try std.testing.expectEqual(@as(u64, 0x3c00_3c00_3c00_3c00), std.mem.readInt(u64, guest.bytes[0x2000 + pixel * 8 ..][0..8], .little));
    std.debug.print("DCC metadata clears passed: repeated RGBA16F compute/PM4/DMA clears, partial and mixed metadata preservation\n", .{});
}

fn runNormalizedColorProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const vertex = [_]u32{
        vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
        vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
        vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
        0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
        vop1(1, 5, 250), 0xff00_e405, // identity DPP shares the graphics lane BuiltIn
        0xf800_08cf,     0x0807_0605,
        0xbf81_0000,
    };
    for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
    const fragment = [_]u32{
        vop1(1, 0, 255), 0x3800_3400, vop1(1, 1, 255), 0x3c00_3a00,
        vop1(1, 2, 255), 0x1234_5678, vop1(1, 3, 255), 0xc000_4000,
        vop1(1, 4, 255), 0x4000_8000, vop1(1, 5, 255), 0x7fff_0000,
        vop1(1, 0, 250), 0xff00_e400, // same identity DPP in the fragment stage
        0xf800_140f, 0x0100, // FP16 ABGR, valid mask
        0xf800_0011, 0x0002, // UINT32 R
        0xf800_0423, 0x0003, // UNORM16 GR
        0xf800_0c3f, 0x0504, // SNORM16 ABGR, done
        0xbf81_0000,
    };
    for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
    var state = gpu.State{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
        try state.writeRegister(.shader, stage.programRegisterBase(), address);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    for ([_]u32{ 10 << 2, (4 << 2) | (4 << 8), 5 << 2, (12 << 2) | (7 << 8) }, 0..) |info, slot| {
        const base: u32 = @intCast(0x318 + slot * 15);
        try state.writeRegister(.context, base, @intCast(0x20 + slot * 0x30));
        try state.writeRegister(.context, base + 1, 3);
        try state.writeRegister(.context, base + 3, 0);
        try state.writeRegister(.context, base + 4, info);
        try state.writeRegister(.context, base + 5, 0);
        try state.writeRegister(.context, 0x390 + @as(u32, @intCast(slot)), 0);
        try state.writeRegister(.context, 0x3b0 + @as(u32, @intCast(slot)), (31 << 14) | 31);
        try state.writeRegister(.context, 0x3b8 + @as(u32, @intCast(slot)), 1 << 24);
    }
    const context = [_][2]u32{
        .{ 0x08e, 0xf31f },                  .{ 0x1c5, 0x6514 },          .{ 0x00c, 0 }, .{ 0x00d, 32 | (32 << 16) },
        .{ 0x094, 1 << 31 },                 .{ 0x095, 32 | (32 << 16) }, .{ 0x1e0, 0 }, .{ 0x200, 0 },
        .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },               .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 16, 16, 16, 16, 1, 0 }, 0..) |value, index| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    try renderer.flushPendingGuestWrites();
    const pixel = 16 * 32 + 16;
    for ([_]u8{ 64, 128, 191, 255 }, guest.bytes[0x2000 + pixel * 4 ..][0..4]) |expected, actual| {
        try std.testing.expect(@abs(@as(i16, actual) - expected) <= 1);
    }
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, guest.bytes[0x5000 + pixel * 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xc000_4000), std.mem.readInt(u32, guest.bytes[0x8000 + pixel * 4 ..][0..4], .little));
    for ([_]f16{ -1, 0.5, 0, 1 }, 0..) |expected, channel| {
        const raw = std.mem.readInt(u16, guest.bytes[0xb000 + pixel * 8 + channel * 2 ..][0..2], .little);
        try std.testing.expectEqual(expected, @as(f16, @bitCast(raw)));
    }
    // Only the export format changes: the same halfwords now represent +2/-2.
    // This also checks that translation/pipeline reuse includes the selector.
    try state.writeRegister(.context, 0x1c5, 0x6414);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), std.mem.readInt(u32, guest.bytes[0x8000 + pixel * 4 ..][0..4], .little));
    try state.writeRegister(.context, 0x1c5, 0x6514);
    const misses = renderer.graphics_pipeline_cache_misses;
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqual(@as(u32, 0xc000_4000), std.mem.readInt(u32, guest.bytes[0x8000 + pixel * 4 ..][0..4], .little));
    try std.testing.expectEqual(misses, renderer.graphics_pipeline_cache_misses);
    std.debug.print("normalized color exports passed: FP16, UINT32, UNORM16 and SNORM16 in separate MRTs\n", .{});

    // A later Yotei pass renders directly into a two-channel signed-normalized
    // attachment before sampling it as RG16_SNORM. Keep both signs intact.
    var signed_fragment = fragment;
    signed_fragment[7] = 0xa000_2000;
    for (signed_fragment, 0..) |word, index| guest.word(0xc00 + index * 4, word);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), 12);
    try state.writeRegister(.context, 0x33a, (5 << 2) | (1 << 8));
    try state.writeRegister(.context, 0x1c5, 0x6614);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    if (renderer.last_draw_error) |err| return err;
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqual(@as(u32, 0xa000_2000), std.mem.readInt(u32, guest.bytes[0x8000 + pixel * 4 ..][0..4], .little));
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), 9);
    try state.writeRegister(.context, 0x33a, 5 << 2);
    try state.writeRegister(.context, 0x1c5, 0x6514);
    std.debug.print("RG16_SNORM attachment passed: positive/negative exports and UNORM/SNORM target reuse\n", .{});

    // AGC attributes name s0:s3 at a later fetch. They must not replace the
    // NGG wave-count input in s3 before the guest loads that descriptor.
    var memory = guest.interface();
    memory.shader_header = struct {
        fn header(_: ?*anyopaque, program: u64) ?u64 {
            return if (program == 0x1000) 0xe000 else null;
        }
    }.header;
    _ = renderer.dcbBackend(memory);
    guest.word(0xe008, 0xe100);
    guest.word(0xe030, 0xe200);
    guest.word(0xe050, 1);
    guest.word(0xe100, 0xe180);
    guest.word(0xe12c, 11);
    @memset(guest.bytes[0xe180..0xe196], 0xff);
    std.mem.writeInt(u16, guest.bytes[0xe190..][0..2], 0, .little); // buffer table in USER_DATA[0:1]
    std.mem.writeInt(u16, guest.bytes[0xe194..][0..2], 2, .little); // attributes in USER_DATA[2:3]
    guest.word(0xe200, 1 << 16); // semantic 0, one element
    guest.word(0xe800, 29 << 5);
    for ([_]u32{ 0x17000, 4 << 16, 1, 0x24fac }, 0..) |word, index| guest.word(0xf000 + index * 4, word);
    guest.word(0x17000, 0x3f800000);
    const merged_vertex = [_]u32{
        vop1(1, 9, 3), // preserve the actual entry s3 before its later V# lifetime
        0xf408_0004, 0xfa00_0000, // s_load_dwordx4 s0, s8, 0
        0xe000_0000, 0x8000_1000, // buffer_load_format_x v16, s0:s3
    } ++ vertex[0 .. vertex.len - 3].* ++ [_]u32{
        0x7d84_12ff,      0x0000_4040, // v_cmp_eq_u32 vcc, 64/64, v9
        vop1(1, 10, 255), 0x4000_0000,
        vop2(1, 7, 10, 7), // Z=2, W=1 rejects a corrupted entry ABI (v7 = 0)
        0xf800_08cf,
        0x0807_0605,
        0xbf81_0000,
    };
    for (merged_vertex, 0..) |word, index| guest.word(0x1000 + index * 4, word);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), 0);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.export_shader.programRegisterBase(), 0x10);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.export_shader.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.geometry.userDataBase() - 1, 4 << 1);
    for ([_]u32{ 0xf000, 0, 0xe800, 0 }, 0..) |word, index| {
        try state.writeRegister(.shader, gpu.resources.ShaderStage.geometry.userDataBase() + @as(u32, @intCast(index)), word);
    }
    try state.writeRegister(.context, 0x318, 0x180);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    try renderer.flushPendingGuestWrites();
    for (renderer.reported_shader_failures) |failure| try std.testing.expect(failure == null);
    for ([_]u8{ 64, 128, 191, 255 }, guest.bytes[0x18000 + pixel * 4 ..][0..4]) |expected, actual| {
        try std.testing.expect(@abs(@as(i16, actual) - expected) <= 1);
    }
    std.debug.print("vertex entry ABI passed: attribute descriptors preserve NGG wave counts before SGPR reuse\n", .{});
}

fn pipelineCacheTimestamp(io: std.Io) !i96 {
    const file = try std.Io.Dir.cwd().openFile(io, "vulkan_pipeline_cache.bin", .{});
    defer file.close(io);
    return (try file.stat(io)).mtime.nanoseconds;
}

fn runPipelineCacheProbe(allocator: std.mem.Allocator) !void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const flip = gpu.state.Flip{ .video_out_handle = 1, .display_buffer_index = 0, .mode = 1, .argument = 0 };
    _ = try renderer.smokeTest();
    renderer.flip_callbacks = 1;
    try std.testing.expect(backend.vtable.flip.?(backend.context, flip));
    const first_generation = renderer.pipeline_cache_generation.load(.acquire);
    // Pipeline creation remains valid while the independent writer extracts
    // the default, internally synchronized driver cache.
    _ = try renderer.smokeTest();
    renderer.pipeline_cache_saver.join();
    try std.testing.expectEqual(first_generation, renderer.pipeline_cache_saver.persisted_generation);
    const first_write = try pipelineCacheTimestamp(io);
    // The newer generation must still be dirty after joining the older save.
    renderer.flip_callbacks = 127;
    try std.testing.expect(backend.vtable.flip.?(backend.context, flip));
    renderer.pipeline_cache_saver.join();
    const second_write = try pipelineCacheTimestamp(io);
    try std.testing.expect(first_write != second_write);
    // A periodic request must not rewrite the now unchanged cache.
    renderer.flip_callbacks = 255;
    try std.testing.expect(backend.vtable.flip.?(backend.context, flip));
    renderer.pipeline_cache_saver.join();
    try std.testing.expectEqual(second_write, try pipelineCacheTimestamp(io));
    std.debug.print("pipeline cache persistence passed: background snapshot, concurrent compilation, later generation saved and unchanged cache preserved\n", .{});
}

fn runIntegerColorProbe(allocator: std.mem.Allocator) !void {
    try runNormalizedColorProbe(allocator);
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

fn runBarycentricProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    if (!renderer.fragment_barycentric_available) return error.SkipZigTest;
    var guest = GuestMemory{};
    var memory = guest.interface();
    memory.shader_header = struct {
        fn header(_: ?*anyopaque, program: u64) ?u64 {
            return if (program == 0x900 or program == 0xa00 or program == 0xb00) 0xe000 else null;
        }
    }.header;
    guest.word(0xe008, 0xe100);
    guest.word(0xe030, 0xe200);
    guest.word(0xe050, 1);
    guest.word(0xe200, 1 << 24); // AGC custom interpolation, raw packed FP16 pairs.
    const vertex = [_]u32{
        vop1(6, 1, 261),  vop1(1, 2, 255),  0x3f80_0000,         vop2(4, 3, 1, 2),
        vop1(1, 4, 255),  0x3f40_0000,      vop2(8, 5, 3, 4),    vop2(8, 6, 3, 3),
        vop1(1, 7, 255),  0xbfc0_0000,      vop2(8, 6, 6, 7),    vop1(1, 8, 255),
        0x3f40_0000,      vop2(3, 6, 6, 8), vop1(1, 7, 128),     vop1(1, 8, 242),
        vop1(1, 9, 255),  0x3e80_0000,      vop2(8, 10, 1, 9),   vop2(3, 12, 10, 9),
        vop1(1, 11, 255), 0x3e00_0000,      vop2(3, 10, 10, 11), vop2(0x2f, 13, 10, 12),
        0xf800_0201,      0x0000_000d,      0xf800_08cf,         0x0807_0605,
        0xbf81_0000,
    };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), 7);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase() + 1, 0);
    const context = [_][2]u32{
        .{ 0x318, 0x20 },                    .{ 0x319, 0 },             .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
        .{ 0x390, 0 },                       .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },       .{ 0x08e, 0xf },     .{ 0x00c, 0 },
        .{ 0x00d, 8 | (8 << 16) },           .{ 0x094, 1 << 31 },       .{ 0x095, 8 | (8 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
        .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },             .{ 0x205, 0 },             .{ 0x191, 0x420 },   .{ 0x1b3, 2 },
        .{ 0x1b4, 0xf8f },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 4, 4, 4, 4, 1, 0 }, 0..) |value, i|
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(memory), .allocator = allocator };
    const Mix = struct {
        fn encode(dst: u8, select: u3, half: u3, negate: u3, sources: [3]u9) [2]u32 {
            return .{
                0xcc20_0000 | @as(u32, dst) | (@as(u32, select) << 11) | (@as(u32, half & 4) << 12),
                @as(u32, sources[0]) | (@as(u32, sources[1]) << 9) | (@as(u32, sources[2]) << 18) |
                    (@as(u32, half & 3) << 27) | (@as(u32, negate) << 29),
            };
        }
    };
    for (0..3) |pass| {
        const basic_fragment = [_]u32{
            0xc802_0002 | (4 << 18),                          0xc802_0000 | (5 << 18),                          0xc802_0001 | (6 << 18),
            vop1(0xb, 4, 260),                                vop1(0xb, 5, 261),                                vop1(0xb, 6, 262),
            vop1(1, 7, 242),
            // Interpolation inputs occupy v2:v3 after the allocated sample pair.
                                             if (pass == 0) 0xbf80_0000 else vop2(4, 8, 5, 4), if (pass == 0) 0xbf80_0000 else vop2(4, 9, 6, 4),
            if (pass == 0) 0xbf80_0000 else vop2(8, 8, 8, 2), if (pass == 0) 0xbf80_0000 else vop2(8, 9, 9, 3), if (pass == 0) 0xbf80_0000 else vop2(3, 4, 4, 8),
            if (pass == 0) 0xbf80_0000 else vop2(3, 4, 4, 9), if (pass == 0) 0xbf80_0000 else vop1(1, 5, 258),  if (pass == 0) 0xbf80_0000 else vop1(1, 6, 259),
            0xf800_080f,                                      0x0706_0504,                                      0xbf81_0000,
        };
        // The tree material unpacks both halves only after fetching each
        // vertex, then combines FP16 endpoints with FP32 barycentric weights.
        const mixed_fragment = [_]u32{
            0xc802_0002 | (4 << 18), 0xc802_0000 | (5 << 18), 0xc802_0001 | (6 << 18),
        } ++ Mix.encode(8, 0, 6, 4, .{ 242, 261, 260 }) ++
            Mix.encode(9, 0, 6, 4, .{ 242, 262, 260 }) ++
            Mix.encode(10, 6, 6, 4, .{ 242, 261, 260 }) ++
            Mix.encode(11, 6, 6, 4, .{ 242, 262, 260 }) ++
            Mix.encode(12, 0, 4, 0, .{ 258, 264, 260 }) ++
            Mix.encode(13, 4, 4, 0, .{ 258, 266, 260 }) ++ [_]u32{
            vop2(0x1f, 12, 9, 3), vop2(0x1f, 13, 11, 3), vop1(1, 14, 258), vop1(1, 7, 242),
            0xf800_080f,          0x070e_0d0c,           0xbf81_0000,
        };
        const fragment: []const u32 = if (pass == 2) &mixed_fragment else &basic_fragment;
        const program: u32 = 0x900 + @as(u32, @intCast(pass)) * 0x100;
        for (fragment, 0..) |word, i| guest.word(program + i * 4, word);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), program >> 8);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        for (1..6) |y| for (1..7) |x| {
            const i = (@as(f32, @floatFromInt(y)) + 0.5 - 1) / 6;
            const j = (@as(f32, @floatFromInt(x)) + 0.5 - 1 - 3 * i) / 6;
            if (j < 0.03 or 1 - i - j < 0.03) continue;
            const expected: [3]f32 = switch (pass) {
                0 => .{ 0.125, 0.375, 0.625 },
                1 => .{ 0.125 + 0.25 * i + 0.5 * j, i, j },
                else => .{ 0.125 + 0.25 * i + 0.5 * j, 0.25 + 0.25 * i + 0.5 * j, i },
            };
            const pixel = guest.bytes[0x2000 + (y * 8 + x) * 4 ..][0..4];
            for (expected, 0..) |value, channel| {
                const want: i32 = @intFromFloat(@round(value * 255));
                if (@abs(@as(i32, pixel[channel]) - want) > 1) {
                    std.debug.print("barycentric pass={d} xy={d},{d} channel={d} want={d} got={d}\n", .{ pass, x, y, channel, want, pixel[channel] });
                    return error.BarycentricMismatch;
                }
            }
        };
    }
    std.debug.print("Barycentric probe passed: distinct packed vertex values, both FP16 halves through MIX, manual interpolation and input allocation holes\n", .{});
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

fn runCubeArrayProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |gradients| for ([_]bool{ false, true }) |mips| {
        try runCubeArrayCase(allocator, gradients, mips, false);
    };
    try runCubeArrayCase(allocator, false, true, true);
}

fn runCubeArrayCase(allocator: std.mem.Allocator, gradients: bool, mips: bool, large: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = SizedGuestMemory(2 * 1024 * 1024){};
    _ = renderer.dcbBackend(guest.interface());
    // Runtime coordinates and LOD share the output buffer. No shader literals
    // change between faces, cubes, mip levels or rebased descriptor views.
    const lod_code = [_]u32{
        0xe038_0000, 0x8003_0000, // buffer_load_dwordx4 v0:v3, s12:s15
        0xbf8c_0f70,
        0xf090_0f18, 0x0040_0800, // image_sample_l cube v8:v11, v0:v3, T#s0, S#s8
        0xbf8c_0f70,
        0xe078_0020, 0x8003_0800, // buffer_store_dwordx4 v8:v11, offset 32
        0xbf81_0000,
    };
    const gradient_code = [_]u32{
        0xe038_0000, 0x8003_0000, // derivatives v0:v3
        0xe038_0010, 0x8003_0400, // coordinates v4:v6
        0xbf8c_0f70,
        0xf088_0f18, 0x0040_0800, // image_sample_d cube
        0xbf8c_0f70, 0xe078_0020,
        0x8003_0800, 0xbf81_0000,
    };
    const code: []const u32 = if (gradients) &gradient_code else &lod_code;
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    const cube_count: u32 = if (large) 17 else 3;
    const face_count = cube_count * 6;
    const width: u32 = if (large) 32 else 4;
    const level_count: usize = if (large) 6 else if (mips) 2 else 1;
    var image = sampledImageDescriptorWords(0x10000, width, width);
    image[3] = (image[3] & 0x0fff_ffff) | (11 << 28) | (@as(u32, @intCast(level_count - 1)) << 16);
    image[4] = face_count - 1;
    image[5] = @as(u32, @intCast(level_count - 1)) << 4;
    const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
    try std.testing.expectEqual(face_count, texture.layers);
    for (0..level_count) |level| {
        const view = try texture.subresource(@intCast(level), 0, face_count);
        for (0..face_count) |layer| for (0..view.height) |y| for (0..view.width) |x| {
            const at = 0x10000 + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), @intCast(layer), 0)));
            const red: u32 = @intCast(32 + (layer / 6) * 9 + (layer % 6) + level * 2);
            const green: u32 = @intCast(11 + x * 7);
            const blue: u32 = @intCast(7 + y * 7);
            guest.word(at, red | (green << 8) | (blue << 16) | 0xff00_0000);
        };
    }
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    var userdata: [16]u32 = @splat(0);
    userdata[8] = 0x92; // clamp to edge, point filtering
    userdata[9] = 0xfff000;
    userdata[10] = 1 << 26; // nearest mip
    @memcpy(userdata[12..16], &[_]u32{ 0x8000, 4 << 16, 16, 0 });
    var cases: usize = 0;
    for ([_]u32{ 0, 6, face_count - 6 }) |base_layer| {
        image[4] = (face_count - 1) | (base_layer << 16);
        userdata[8] = if (base_layer == 6) 0 else 0x92; // also exercise view reuse with another sampler
        @memcpy(userdata[0..8], &image);
        for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
        for (0..(face_count - base_layer) / 6) |cube| for (0..6) |face| for (0..level_count) |level| for (0..2) |corner| {
            const extent: usize = @as(usize, width) >> @as(u6, @intCast(level));
            const x: usize = if (corner == 0) 0 else extent - 1;
            const y: usize = if (corner == 0) extent - 1 else 0;
            const coordinates = [_]f32{
                1.0 + (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(extent)),
                1.0 + (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(extent)),
                @floatFromInt(cube * 8 + face),
                @floatFromInt(level),
            };
            for (coordinates, 0..) |value, i| guest.word(0x8000 + @as(usize, if (gradients) 16 else 0) + i * 4, @bitCast(value));
            if (gradients) {
                const footprint = 1.0 / @as(f32, @floatFromInt(extent));
                for ([_]f32{ footprint, 0, 0, footprint }, 0..) |value, i| guest.word(0x8000 + i * 4, @bitCast(value));
            }
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var bytes: [64]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x8000, &bytes);
            const expected = [_]u32{ @intCast(32 + (base_layer / 6 + cube) * 9 + face + level * 2), @intCast(11 + x * 7), @intCast(7 + y * 7), 255 };
            for (expected, 0..) |channel, i| {
                const actual: f32 = @bitCast(std.mem.readInt(u32, bytes[32 + i * 4 ..][0..4], .little));
                const want = @as(f32, @floatFromInt(channel)) / 255.0;
                if (@abs(actual - want) > 0.00001) {
                    std.debug.print("cube mismatch base={d} cube={d} face={d} mip={d} xy={d},{d} channel={d}: actual={d} expected={d}\n", .{ base_layer, cube, face, level, x, y, i, actual, want });
                    return error.CubeArraySampleMismatch;
                }
            }
            cases += 1;
        };
    }
    std.debug.print("Cube sampling passed: {d} cases, six face orientations, {d} cubes, mips={d}, gradients={any}, rebased views\n", .{ cases, cube_count, level_count, gradients });
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

fn runFlatWaveSnapshotProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 4, 256),
        mubuf(0x0d, 0, 0, 4, 8)[0],
        mubuf(0x0d, 0, 0, 4, 8)[1],
        0xdc38_8000,
        0x007d_0000,
        mubuf(0x1e, 0, 0, 4, 12)[0],
        mubuf(0x1e, 0, 0, 4, 12)[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
    defer analysis.deinit(allocator);
    for ([_]bool{ false, true }) |bvh_mode1| {
        if (bvh_mode1 and !renderer.storage_buffer_nonuniform_indexing) continue;
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .local_size = .{ 64, 1, 1 },
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{
                .{ .resource_sgpr = 8, .descriptor_index = 0, .stride = 8 },
                .{ .resource_sgpr = 12, .descriptor_index = 1, .stride = 16 },
            },
            .flat_memories = &.{ .{ .descriptor_index = 2, .fault_record_word = 20 }, .{ .descriptor_index = 3 } },
            .bvh_intersection_mode1 = bvh_mode1,
        });
        defer module.deinit(allocator);
        for (0..2) |pass| {
            const base: u64 = 0x20_ffff_fff0 + (@as(u64, @intCast(pass)) << 36);
            const offsets = [_]i64{ 0, 17, 24, 44, 60, 64, -4, 0x1_0000_0000 };
            for (0..64) |lane| {
                const pointer: u64 = @intCast(@as(i64, @intCast(base)) + offsets[lane % offsets.len]);
                guest.word(0x10000 + lane * 8, @truncate(pointer));
                guest.word(0x10004 + lane * 8, @truncate(pointer >> 32));
            }
            var first: [64]u8 = undefined;
            var last: [32]u8 = undefined;
            for (&first, 0..) |*byte, index| byte.* = @intCast(0x10 + index + pass);
            for (&last, 0..) |*byte, index| byte.* = @intCast(0xa0 + index + pass);
            for (0..2) |region| {
                const at = 0x12000 + region * 0x100;
                const address = base + region * 16;
                const data: []const u8 = if (region == 0) &first else &last;
                guest.word(at, @truncate(address));
                guest.word(at + 4, @truncate(address >> 32));
                guest.word(at + 8, 0);
                guest.word(at + 12, @intCast(data.len));
                @memcpy(guest.bytes[at + 16 ..][0..data.len], data);
            }
            @memset(guest.bytes[0x12050..0x12060], 0);
            _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 64 * 8);
            _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 64 * 16);
            _ = try renderer.stageGuestStorageBufferAt(2, 0x12000, 96);
            _ = try renderer.stageGuestStorageBufferAt(3, 0x12100, 48);
            _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
            var output: [64 * 16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x11000, &output);
            var faults: u32 = 0;
            for (0..64) |lane| for (0..4) |word| {
                const relative = offsets[lane % offsets.len] + @as(i64, @intCast(word * 4));
                const expected = if (relative >= 16 and relative + 4 <= 48)
                    std.mem.readInt(u32, last[@intCast(relative - 16)..][0..4], .little)
                else if (relative >= 0 and relative + 4 <= 64)
                    std.mem.readInt(u32, first[@intCast(relative)..][0..4], .little)
                else blk: {
                    faults += 1;
                    break :blk @as(u32, 0);
                };
                try std.testing.expectEqual(expected, std.mem.readInt(u32, output[lane * 16 + word * 4 ..][0..4], .little));
            };
            var header: [96]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x12000, &header);
            try std.testing.expectEqual(faults, std.mem.readInt(u32, header[8..12], .little));
            try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, header[80..84], .little));
        }
    }
    std.debug.print("FLAT wave snapshots passed: divergent descriptors, last overlapping region wins, unaligned loads, relocation, partial vector bounds and faults\n", .{});
}

fn runFlatPointerProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    for ([_]bool{ false, true }) |bvh_mode1| for ([_]bool{ false, true }) |repeat| for ([_]u32{ 125, 0, 106 }) |saddr| for ([_]i32{ -4, 0, 4 }) |offset| {
        if (bvh_mode1 and !renderer.storage_buffer_nonuniform_indexing) continue;
        const scalar_base = saddr != 125;
        const code = [_]u32{
            if (repeat) 0xbe9e_0382 else 0xbf80_0000, // two iterations, or a straight-line probe
            vop1(1, 4, 20),
            0xb814_0008,
            0xf424_0004 | (if (saddr == 106) @as(u32, 106 << 6) else 0), 20 << 25, // pointer table -> s0:s1 or VCC
            vop1(1, 0, if (scalar_base) 136 else 0),                     vop1(1, 1, 1),
            0xdc38_8000 | (@as(u32, @bitCast(offset)) & 0xfff),
            saddr << 16, // x4 -> v0:v3, overlapping address
            mubuf(0x1e, 0, 0, 4, 12)[0],
            mubuf(0x1e, 0, 0, 4, 12)[1],
            if (repeat) 0x811e_c11e else 0xbf80_0000, // s30 -= 1
            if (repeat) 0xbf06_801e else 0xbf80_0000, // s30 == 0
            if (repeat) 0xbf84_fff5 else 0xbf80_0000, // SCC0 -> pointer load, preserving the original workgroup index
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
            .flat_memories = &.{ .{ .descriptor_index = 2, .fault_record_word = 12 }, .{ .descriptor_index = 3 } },
            .bvh_intersection_mode1 = bvh_mode1,
        });
        defer module.deinit(allocator);
        for (0..2) |pass| {
            const base: u64 = 0x20_ffff_fff0 + (@as(u64, @intCast(pass)) << 36);
            const pointers = [_]u64{ base, base + 1, base + 24, base - 4, base + 64, base + 0x1_0000_0000 };
            var source: [64]u8 = undefined;
            for (&source, 0..) |*byte, index| byte.* = @intCast(index + 1);
            for (pointers, 0..) |pointer, index| {
                guest.word(0x10000 + index * 8, @truncate(pointer));
                guest.word(0x10004 + index * 8, @truncate(pointer >> 32));
            }
            for (0..2) |region| {
                const at = 0x12000 + region * 0x100;
                const address = base + region * 32;
                guest.word(at, @truncate(address));
                guest.word(at + 4, @truncate(address >> 32));
                guest.word(at + 8, 0);
                guest.word(at + 12, 32);
                for (0..8) |word| guest.word(at + 16 + word * 4, std.mem.readInt(u32, source[region * 32 + word * 4 ..][0..4], .little));
            }
            _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, pointers.len * 8);
            _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, pointers.len * 16);
            for (0..4) |word| guest.word(0x12030 + word * 4, 0);
            _ = try renderer.stageGuestStorageBufferAt(2, 0x12000, 64);
            _ = try renderer.stageGuestStorageBufferAt(3, 0x12100, 48);
            _ = try renderer.dispatchSpirv(module.words, .{ pointers.len, 1, 1 });
            var output: [pointers.len * 16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x11000, &output);
            var faults: u32 = 0;
            for (pointers, 0..) |pointer, index| for (0..4) |word| {
                const address: i64 = @as(i64, @intCast(pointer)) + (if (scalar_base) @as(i64, 8) else 0) + offset + @as(i64, @intCast(word * 4));
                const relative = address - @as(i64, @intCast(base));
                const valid = relative >= 0 and relative + 4 <= 64 and @mod(relative, 32) <= 28;
                const expected = if (valid) std.mem.readInt(u32, source[@intCast(relative)..][0..4], .little) else blk: {
                    faults += 1;
                    break :blk @as(u32, 0);
                };
                try std.testing.expectEqual(expected, std.mem.readInt(u32, output[index * 16 + word * 4 ..][0..4], .little));
            };
            var header: [64]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x12000, &header);
            try std.testing.expectEqual(faults * @as(u32, if (repeat) 2 else 1), std.mem.readInt(u32, header[8..12], .little));
            try std.testing.expectEqual(@as(u32, 28), std.mem.readInt(u32, header[48..52], .little));
            const failed_address = std.mem.readInt(u64, header[52..60], .little);
            const failed_component = std.mem.readInt(u32, header[60..64], .little);
            try std.testing.expect(failed_component < 4);
            const failed_relative = @as(i64, @intCast(failed_address)) - @as(i64, @intCast(base));
            try std.testing.expect(!(failed_relative >= 0 and failed_relative + 4 <= 64 and @mod(failed_relative, 32) <= 28));
            var matches_failed_read = false;
            for (pointers) |pointer| {
                const address = @as(i64, @intCast(pointer)) + (if (scalar_base) @as(i64, 8) else 0) + offset + @as(i64, failed_component) * 4;
                matches_failed_read = matches_failed_read or address == failed_address;
            }
            try std.testing.expect(matches_failed_read);
        }
    };
    std.debug.print("FLAT pointers passed: absolute/SGPR/VCC bases, signed offsets, overlapping destinations, unaligned reads, 4-GiB carry, relocation, repeated loop reads and fault counts\n", .{});
}

fn runCleanBufferRetentionProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |use_waits| try runQueuedBufferReuseProbe(allocator, use_waits, true, 0);
    for ([_]bool{ false, true }) |retain| {
        var renderer = try vulkan.Renderer.init(allocator, .{
            .enable_timeline_scheduler = true,
            .retain_clean_storage_buffers = retain,
            .storage_buffer_cache_budget_bytes = 128 * 16,
        });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        var handles: [96]u64 = undefined;
        for (&handles, 0..) |*handle, index| {
            const address = 0x10000 + index * 16;
            guest.word(address, @intCast(0x1234 + index));
            handle.* = (try renderer.stageGuestStorageBufferAt(0, address, 16)).buffer;
        }
        const misses = renderer.buffer_cache_misses;
        for (handles, 0..) |handle, index| {
            const address = 0x10000 + index * 16;
            const buffer = try renderer.stageGuestStorageBufferAt(0, address, 16);
            if (retain) try std.testing.expectEqual(handle, buffer.buffer);
            var actual: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(address, &actual);
            try std.testing.expectEqual(@as(u32, @intCast(0x1234 + index)), std.mem.readInt(u32, actual[0..4], .little));
        }
        try std.testing.expectEqual(@as(u64, if (retain) 0 else 96), renderer.buffer_cache_misses - misses);
        // A changed source must refresh even when the allocation is retained.
        guest.word(0x10000, 0xaabb_ccdd);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 16);
        var changed: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &changed);
        try std.testing.expectEqual(@as(u32, 0xaabb_ccdd), std.mem.readInt(u32, changed[0..4], .little));
        // Once the byte budget is full, changing the slot keeps recycling.
        for (96..256) |index| _ = try renderer.stageGuestStorageBufferAt(0, 0x10000 + index * 16, 16);
        if (retain) try std.testing.expectEqual(@as(usize, 128), renderer.guest_buffers.items.len);
    }
    std.debug.print("Clean buffer retention passed: 96 ranges through one descriptor, refreshed CPU writes, byte-budget recycling\n", .{});
}

fn runBufferCacheBudgetProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |retain| {
        for ([_]bool{ false, true }) |local| {
            var renderer = try vulkan.Renderer.init(allocator, .{
                .enable_timeline_scheduler = true,
                .retain_clean_storage_buffers = retain,
                .storage_buffer_cache_budget_bytes = 8192,
                .device_storage_budget_bytes = if (local) 8192 else 0,
            });
            defer renderer.deinit();
            var guest = GuestMemory{};
            _ = renderer.dcbBackend(guest.interface());
            const code = [_]u32{ 0xe0300000, 0x80020000, 0xe0700000, 0x80030000, 0xbf810000 };
            for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
            var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
            defer analysis.deinit(allocator);
            var module = try analysis.translateSpirv(allocator, .{
                .stage = .compute,
                .local_size = .{ 1, 1, 1 },
                .storage_buffers = &.{
                    .{ .resource_sgpr = 8, .descriptor_index = 0, .extent_bytes = 512 },
                    .{ .resource_sgpr = 12, .descriptor_index = 1, .extent_bytes = 512 },
                },
            });
            defer module.deinit(allocator);
            guest.word(0x1000, 0x12345678);
            guest.word(0x3000, 0xabcdef01);
            _ = try renderer.stageGuestStorageBufferAt(0, 0x1000, 512);
            _ = try renderer.stageGuestStorageBufferAt(1, 0x2000, 512);
            const protected = try renderer.stageGuestStorageBufferAt(2, 0x3000, 512);
            renderer.draw_batch_active = true;
            renderer.current_descriptor_slot = 0;
            _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
            for (renderer.guest_buffers.items) |*entry|
                if (entry.guest_address == 0x2000) {
                    entry.gpu_dirty = true;
                };
            renderer.current_descriptor_slot = 1;
            renderer.descriptor_set = renderer.descriptor_sets[1];
            renderer.active_storage_buffers[0] = 0;
            renderer.active_storage_buffers[1] = 0;
            // Recycling 512 bytes for a 16-byte range keeps its old capacity
            // in the default mode. The subsequent trim must count that space.
            _ = try renderer.stageGuestStorageBufferAt(0, 0x4000, 16);
            renderer.active_storage_buffers[0] = 0;
            renderer.storage_buffer_cache_budget_bytes = if (local) 1200 else 600;
            guest.word(0x5000, 0x87654321);
            _ = try renderer.stageGuestStorageBufferAt(0, 0x5000, 16);
            try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, guest.bytes[0x2000..][0..4], .little));
            var allocated: u64 = 0;
            var found_protected = false;
            for (renderer.guest_buffers.items) |entry| {
                allocated += entry.device_local.size;
                if (entry.host_transfer) |transfer| allocated += transfer.size;
                if (entry.guest_address == 0x3000) {
                    found_protected = true;
                    try std.testing.expectEqual(protected.buffer, entry.device_local.handle);
                }
            }
            try std.testing.expect(found_protected);
            try std.testing.expect(allocated <= renderer.storage_buffer_cache_budget_bytes);
            var actual: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x5000, &actual);
            try std.testing.expectEqual(@as(u32, 0x87654321), std.mem.readInt(u32, actual[0..4], .little));
            renderer.draw_batch_active = false;
            renderer.current_descriptor_slot = null;
        }
    }
    std.debug.print("buffer cache budget passed: oversized capacity, both retention modes, transfer mirrors, pending GPU writes and protected bindings\n", .{});
}

fn runScratchMemoryProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    try code.appendSlice(allocator, &.{
        vop1(1, 1, 255), 0xaabbccdd,
        vop1(1, 2, 128), vop1(1, 3, 255),
        0x70000000,
        0xdc74_0000, 0x0000_0002, // FLAT private store x2 from v0:v1
        0xdc34_4000,     0x107d_0002, // SCRATCH load x2 -> v16:v17
        vop1(1, 4, 255), 0x11223344,
        vop1(1, 5, 255), 0x55667788,
        vop1(1, 2, 136), 0xdc74_4000, 0x007d_0402, // scratch store at 8
        0xdc34_0000,     0x1200_0002, // FLAT load -> v18:v19
        vop1(1, 4, 255), 0x01020304,
        vop1(1, 2, 129),
        0xdc70_4000,     0x007d_0402, // misaligned store at 1
        vop1(1, 2, 128), 0xdc34_4000,
        0x147d_0002,
        vop1(1, 2, 133), 0xdc30_4ffc,     0x167d_0002, // signed immediate: 5 - 4
        sop1(3, 6, 136), vop1(1, 2, 128),
        0xdc30_4000, 0x1706_0002, // scalar offset 8 ignores vector offset 0
        vop1(1, 2, 140), 0xdc30_4000, 0x187f_0002, // alternate NULL SADDR
        vop1(1, 2, 144), 0xdc30_4000, 0x197d_0002,
        0xdc70_4000,     0x007d_0402, // out-of-bounds write must not alias offset 0
        vop1(1, 2, 128), 0xdc30_4000,
        0x1a7d_0002,
        vop1(1, 2, 142), 0xdc30_4000, 0x1b7d_0002, // partially outside dword
        vop1(1, 2, 136),  0xdc34_4000,      0x027d_0002, // destination overlaps address
        vop1(1, 28, 258), vop1(1, 29, 259),
        vop1(1, 2, 140), 0xdc34_4000, 0x1e7d_0002, // x2 crosses allocation end
    });
    for (0..4) |group| try code.appendSlice(allocator, &mubuf(0x1e, @intCast(group * 16), @intCast(16 + group * 4), 0, 12));
    try code.append(allocator, 0xbf81_0000);
    for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.items.len);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 32, 1, 1 },
        .wave32 = true,
        .compute_inputs = .{ .local_invocation_id_components = 1 },
        .private_memory_size_bytes = 16,
        .flat_apertures = .{ .private = 0x70000000 },
        .storage_buffers = &.{.{ .resource_sgpr = 12, .descriptor_index = 0, .stride = 64 }},
        .flat_memories = &.{.{ .descriptor_index = 1, .fault_record_word = 8 }},
    });
    defer module.deinit(allocator);
    guest.word(0x12000, 0x1230);
    guest.word(0x12004, 0x20);
    guest.word(0x1200c, 4);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x11000, 32 * 64);
    _ = try renderer.stageGuestStorageBufferAt(1, 0x12000, 48);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    var output: [32 * 64]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x11000, &output);
    for (0..32) |lane| {
        const altered: u32 = 0x02030400 | @as(u32, @intCast(lane));
        const expected = [_]u32{ @intCast(lane), 0xaabbccdd, 0x11223344, 0x55667788, altered, 0xaabbcc01, 0x01020304, 0x11223344, 0x55667788, 0, altered, 0, 0x11223344, 0x55667788, 0x55667788, 0 };
        for (expected, 0..) |value, word| {
            const actual = std.mem.readInt(u32, output[lane * 64 + word * 4 ..][0..4], .little);
            if (actual != value) std.debug.print("SCRATCH lane={d} word={d} expected={x} actual={x}\n", .{ lane, word, value, actual });
            try std.testing.expectEqual(value, actual);
        }
    }
    var header: [48]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x12000, &header);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, header[8..12], .little));
    std.debug.print("SCRATCH passed: FLAT aliasing, lane isolation, scalar/vector offsets, signed offsets, misalignment, overlapping destinations and bounds\n", .{});
}

fn runUnboundSnapshotProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        sop1(3, 0, 255), 0x1000, sop1(3, 1, 255), 0x20,
        0xf408_0200,                0xfa00_0000, // runtime V# s8 <- pointer s0
        mubuf(0x0d, 0, 2, 0, 8)[0], mubuf(0x0d, 0, 2, 0, 8)[1],
        sop1(3, 106, 134), // VCC is a scalar byte offset of 6, aligned to 4 by SMEM
        0xf424_0504,                 106 << 25, // s_buffer_load_dwordx2 s20, V#s8, VCC
        vop1(1, 4, 20),              vop1(1, 5, 21),
        mubuf(0x1e, 0, 2, 0, 12)[0], mubuf(0x1e, 0, 2, 0, 12)[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 8, 1, 1 },
        .wave32 = true,
        .compute_inputs = .{ .local_invocation_id_components = 1 },
        .snapshot_unbound_reads = true,
        .storage_buffers = &.{.{ .resource_sgpr = 12, .descriptor_index = 0, .stride = 16 }},
        .flat_memories = &.{.{ .descriptor_index = 1, .fault_record_word = 132 }},
    });
    defer module.deinit(allocator);
    guest.word(0x12000, 0x1000);
    guest.word(0x12004, 0x20);
    guest.word(0x1200c, 512);
    for ([_]u32{ 0x1080, 0x80020, 4, 0x16204 }, 0..) |word, index| guest.word(0x12010 + index * 4, word);
    for (0..8) |index| guest.word(0x12090 + index * 4, @intCast(0xabc00000 + index));
    for (0..2) |missing| {
        guest.word(0x12004, if (missing == 0) 0x20 else 0x21);
        guest.word(0x12008, 0);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x11000, 8 * 16);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x12000, 544);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [8 * 16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for (0..8) |lane| for (0..4) |word| {
            const expected: u32 = if (missing != 0 or (word < 2 and lane >= 4)) 0 else if (word < 2) @intCast(0xabc00000 + lane * 2 + word) else @intCast(0xabc00001 + word - 2);
            const actual = std.mem.readInt(u32, output[lane * 16 + word * 4 ..][0..4], .little);
            if (actual != expected) std.debug.print("snapshot case={d} lane={d} word={d} expected={x} actual={x}\n", .{ missing, lane, word, expected, actual });
            try std.testing.expectEqual(expected, actual);
        };
        var header: [544]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x12000, &header);
        try std.testing.expectEqual(@as(u32, if (missing == 0) 0 else 32), std.mem.readInt(u32, header[8..12], .little));
    }
    std.debug.print("Unbound snapshot reads passed: runtime SMEM descriptor, indexed MUBUF, scalar VCC offsets, bounds and missing-pointer faults\n", .{});
}

fn runBvhIntersectionProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    // The captured instruction uses NSA operands and overwrites v2:v5.
    const registers = [_]u8{ 43, 55, 57, 34, 56, 37, 36, 54, 62, 63, 25 };
    for (registers, 0..) |reg, component| try code.appendSlice(allocator, &mubuf(0x0c, @intCast(component * 4), reg, 0, 0));
    for ([_]u32{ 0x20000010, 0x80000000, 8, 0x81000000 }, 24..) |word, reg|
        try code.appendSlice(allocator, &.{ sop1(3, @intCast(reg), 255), word });
    try code.appendSlice(allocator, &.{ 0xf198_9f07, 0x0006_022b, 0x3822_3937, 0x3e36_2425, 0x0000_193f });
    try code.appendSlice(allocator, &mubuf(0x1e, 0, 2, 0, 12));
    try code.append(allocator, 0xbf81_0000);
    for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.items.len);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 16, 1, 1 },
        .wave32 = true,
        .compute_inputs = .{ .local_invocation_id_components = 1 },
        .bvh_intersection_mode1 = true,
        .storage_buffers = &.{ .{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 44 }, .{ .resource_sgpr = 12, .descriptor_index = 1, .stride = 16 } },
        .flat_memories = &.{.{ .descriptor_index = 2, .fault_record_word = 148 }},
    });
    defer module.deinit(allocator);
    const snapshot = 0x12000;
    guest.word(snapshot, 0x1000);
    guest.word(snapshot + 4, 0x20);
    guest.word(snapshot + 8, 0);
    guest.word(snapshot + 12, 576);
    const vertices = [5][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 0, 1 }, .{ 2, 1 }, .{ -2, 2 } };
    const triangles = [4][3]usize{ .{ 0, 1, 2 }, .{ 1, 3, 2 }, .{ 2, 3, 4 }, .{ 2, 4, 0 } };
    for (0..4) |kind| {
        const at = snapshot + 16 + (kind + 1) * 64;
        for (vertices, 0..) |vertex, index| {
            guest.word(at + index * 12, @bitCast(vertex[0]));
            guest.word(at + index * 12 + 4, @bitCast(vertex[1]));
            guest.word(at + index * 12 + 8, @bitCast(@as(f32, @floatFromInt(2 + kind * 2))));
        }
        // Identity barycentric swizzle (I=1, J=2) for each of four triangles.
        guest.word(at + 60, 0x09090909);
    }
    for ([_]bool{ false, true }) |half| {
        const at = snapshot + 16 + @as(usize, if (half) 8 else 6) * 64;
        for ([_]u32{ 3, 1, 0, 2 }, 0..) |kind, child| {
            guest.word(at + child * 4, (kind + 1) * 8 + kind);
            const z: f32 = @floatFromInt(2 + kind * 2);
            const bounds = [_]f32{ -10, -10, z, 10, 10, z + 0.5 };
            if (half) {
                for (0..3) |pair| {
                    const a: u16 = @bitCast(@as(f16, @floatCast(bounds[pair * 2])));
                    const b: u16 = @bitCast(@as(f16, @floatCast(bounds[pair * 2 + 1])));
                    guest.word(at + 16 + child * 12 + pair * 4, @as(u32, a) | (@as(u32, b) << 16));
                }
            } else for (bounds, 0..) |value, component| guest.word(at + 16 + child * 24 + component * 4, @bitCast(value));
        }
    }
    for (0..16) |lane| {
        const kind = lane % 4;
        const tri = triangles[kind];
        const x = (vertices[tri[0]][0] + vertices[tri[1]][0] + vertices[tri[2]][0]) / 3;
        const y = (vertices[tri[0]][1] + vertices[tri[1]][1] + vertices[tri[2]][1]) / 3;
        const ray = [_]u32{
            if (lane == 12) 6 * 8 + 5 else if (lane == 13) 8 * 8 + 4 else if (lane == 14) 9 * 8 else if (lane == 15) 0x1e else @intCast((kind + 1) * 8 + kind),
            @bitCast(@as(f32, 20)),
            @bitCast(@as(f32, if (lane >= 12) 0 else if (lane >= 4 and lane < 8) 100 else x)),
            @bitCast(@as(f32, if (lane >= 12) 0 else y)),
            @bitCast(@as(f32, if (lane >= 8 and lane < 12) 10 else 0)),
            0,
            0,
            if (lane >= 8 and lane < 12) 0xbf800000 else 0x3f800000,
            0x7f800000,
            0x7f800000,
            if (lane >= 8 and lane < 12) 0xbf800000 else 0x3f800000,
        };
        for (ray, 0..) |word, component| guest.word(0x10000 + lane * 44 + component * 4, word);
    }
    _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 16 * 44);
    _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 16 * 16);
    _ = try renderer.stageGuestStorageBufferAt(2, snapshot, 608);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    var output: [16 * 16]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x11000, &output);
    for (0..16) |lane| {
        var words: [4]u32 = undefined;
        for (&words, 0..) |*word, component| word.* = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
        std.debug.print("BVH lane={d} result={x}/{x}/{x}/{x}\n", .{ lane, words[0], words[1], words[2], words[3] });
        if (lane >= 14) {
            try std.testing.expectEqualSlices(u32, &.{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff }, &words);
        } else if (lane >= 12) {
            try std.testing.expectEqualSlices(u32, &.{ 8, 17, 26, 35 }, &words);
        } else if (lane >= 4 and lane < 8) {
            try std.testing.expectEqual(@as(u32, 0x7f800000), words[0]);
        } else {
            const denom: f32 = @bitCast(words[1]);
            const distance: f32 = @as(f32, @bitCast(words[0])) / denom;
            const z: f32 = @floatFromInt(2 + (lane % 4) * 2);
            try std.testing.expectApproxEqAbs(if (lane >= 8) 10 - z else z, distance, 0.0001);
            for (words[2..]) |word| try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), @as(f32, @bitCast(word)) / denom, 0.0001);
        }
    }
    var header: [608]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(snapshot, &header);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, header[8..12], .little));
    // A missing snapshot is a recorded failure, whereas hardware node bounds
    // and reserved node types above were ordinary misses without faults.
    guest.word(snapshot + 4, 0x21);
    _ = try renderer.stageGuestStorageBufferAt(2, snapshot, 608);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(snapshot, &header);
    try std.testing.expectEqual(@as(u32, 14), std.mem.readInt(u32, header[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0x20), std.mem.readInt(u32, header[600..604], .little));
    std.debug.print("BVH intersections passed: four triangle types, two sides, misses, FP32/FP16 sorted boxes, node bounds, reserved nodes and missing-memory faults\n", .{});
}

fn runFlatApertureProbe(allocator: std.mem.Allocator) !void {
    for (0..4) |failure| {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const code = [_]u32{
            0x3402_0082, // v1 = local ID * 4
            0xd834_0000, 0x0000_0001, // DS write [v1] = local ID
            0xbf8a_0000, // barrier before a different lane reads
            0x3a04_00bf, // v2 = local ID XOR 63
            0x3404_0482,
            vop1(1, 3, 255),
            0x8000_0000,
            0xdc30_0000,     0x0800_0002, // LDS FLAT load -> v8
            vop1(1, 2, 257),
            0xdc70_0100, 0x0000_0002, // FLAT store [v2:v3+256] = v0
            0xd8d8_0100,     0x0900_0001, // DS read same address -> v9
            vop1(1, 2, 128), vop1(1, 3, 255),
            0x7000_0000,
            0xdc70_0000, 0x0000_0002, // private store; all lanes use offset 0
            0xbf8a_0000,
            0xdc30_0000,     0x0a00_0002, // private load -> v10
            vop1(1, 2, 255), if (failure == 1) 512 else if (failure == 2) 16 else 0x1230,
            vop1(1, 3, 255), if (failure == 1) 0x8000_0000 else if (failure == 2) 0x7000_0000 else if (failure == 3) 0x9000_0000 else 0x20,
            0xdc30_0000,                 0x0b00_0002, // global snapshot or deliberately unmapped load
            mubuf(0x1e, 0, 8, 0, 12)[0], mubuf(0x1e, 0, 8, 0, 12)[1],
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
        defer analysis.deinit(allocator);
        var module = try analysis.translateSpirv(allocator, .{
            .stage = .compute,
            .local_size = .{ 64, 1, 1 },
            .wave32 = true,
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .workgroup_memory_size_bytes = 512,
            .private_memory_size_bytes = 16,
            .flat_apertures = .{ .shared = 0x8000_0000, .private = 0x7000_0000 },
            .storage_buffers = &.{.{ .resource_sgpr = 12, .descriptor_index = 0, .stride = 16 }},
            .flat_memories = &.{.{ .descriptor_index = 1, .fault_record_word = 8 }},
        });
        defer module.deinit(allocator);
        guest.word(0x12000, 0x1230);
        guest.word(0x12004, 0x20);
        guest.word(0x12008, 0);
        guest.word(0x1200c, 4);
        guest.word(0x12010, 0xaabb_ccdd);
        _ = try renderer.stageGuestStorageBufferAt(0, 0x11000, 64 * 16);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x12000, 48);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [64 * 16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for (0..64) |lane| {
            const expected = [_]u32{ @intCast(lane ^ 63), @intCast(lane), @intCast(lane), if (failure == 0) 0xaabb_ccdd else 0 };
            for (expected, 0..) |value, word| {
                const actual = std.mem.readInt(u32, output[lane * 16 + word * 4 ..][0..4], .little);
                if (actual != value) std.debug.print("FLAT aperture case={d} lane={d} word={d} expected={x} actual={x}\n", .{ failure, lane, word, value, actual });
                try std.testing.expectEqual(value, actual);
            }
        }
        var header: [48]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x12000, &header);
        try std.testing.expectEqual(@as(u32, if (failure == 3) 64 else 0), std.mem.readInt(u32, header[8..12], .little));
        if (failure == 3) {
            try std.testing.expectEqual(@as(u32, if (failure == 1) 0x8000_0000 else if (failure == 2) 0x7000_0000 else 0x9000_0000), std.mem.readInt(u32, header[40..44], .little));
        }
    }
    std.debug.print("FLAT apertures passed: DS/FLAT aliasing across lanes, private isolation, global snapshots and precise unmapped aperture faults\n", .{});
}

fn runSceneFlatPointerProbe(allocator: std.mem.Allocator) !void {
    for (0..4) |variant| {
        const scene_bounds = variant == 1;
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        // Preserve the captured pointer-walk sites, with NOPs in place of its
        // culling math. All memory discovery, upload and fault checks are live.
        var code: [0x3b6c / 4]u32 = @splat(0xbf80_0000);
        code[0] = vop1(1, 4, 128);
        code[0x3ad4 / 4] = 0xdc34_8018;
        code[0x3ad8 / 4] = 0x0400_0004;
        code[0x3ae0 / 4] = 0xdc30_8098;
        code[0x3ae4 / 4] = 0x067d_0004;
        code[0x3b3c / 4] = 0xdc34_8088;
        code[0x3b40 / 4] = 0x0e7d_0004;
        if (scene_bounds) {
            code[0] = vop1(1, 0, 128);
            @memset(code[0x3ad4 / 4 .. 0x3b44 / 4], 0xbf80_0000);
            code[0x65c / 4] = 0xdc34_8018;
            code[0x660 / 4] = 0x0000_0000;
            code[0x668 / 4] = 0xdc30_8098;
            code[0x66c / 4] = 0x027d_0000;
            code[0x6c4 / 4] = 0xdc34_8088;
            code[0x6c8 / 4] = 0x087d_0000;
            code[0x6cc / 4] = vop1(1, 14, 264);
            code[0x6d0 / 4] = vop1(1, 15, 265);
        }
        if (variant >= 2) {
            @memset(code[0x3ad4 / 4 .. 0x3b44 / 4], 0xbf80_0000);
            code[0] = vop1(1, 2, 128);
            const pc: usize = if (variant == 2) 0x6ac else 0x6a0;
            @memcpy(code[pc / 4 ..][0..2], &[_]u32{ 0xdc34_8018, 0x0200_0002 });
            @memcpy(code[(pc + 12) / 4 ..][0..2], &[_]u32{ 0xdc30_8098, 0x047d_0002 });
            @memcpy(code[(pc + 104) / 4 ..][0..2], &[_]u32{ 0xdc34_8088, 0x0a7d_0002 });
            code[(pc + 112) / 4] = vop1(1, 14, 266);
            code[(pc + 116) / 4] = vop1(1, 15, 267);
        }
        // The real culling shaders form 64-bit record addresses with VOP3B
        // carry-out followed by VOP2 ADDC. A stale VCC must not add 4 GiB.
        code[0x3b44 / 4] = sop1(4, 106, 193);
        code[0x3b48 / 4] = 0xd70f_6a0e;
        code[0x3b4c / 4] = 270 | (128 << 9);
        code[0x3b50 / 4] = 0x501e_1e80;
        code[0x3b54 / 4] = 0xdc38_8000;
        code[0x3b58 / 4] = 0x007d_000e;
        code[0x3b5c / 4] = vop1(1, 8, 128);
        code[0x3b60 / 4] = mubuf(0x1e, 0, 0, 8, 4)[0];
        code[0x3b64 / 4] = mubuf(0x1e, 0, 0, 8, 4)[1];
        code[0x3b68 / 4] = 0xbf81_0000;
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        guest.word(0x10010, 1);
        guest.word(0x10018, 0x11000);
        guest.word(0x11000 + 140, 168 << 16);
        guest.word(0x11000 + 144, 1);
        guest.word(0x11000 + 148, 0x5204);
        guest.word(0x11000 + 152, 1);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, 1);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, 8 << 1);
        const user_data = [_]u32{ 0x10000, 0, 0, 0, 0x13000, 16 << 16, 1, (20 << 12) | 0xfac };
        for (user_data, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        for (0..2) |pass| {
            const records = 0x12000 + pass * 0x2000;
            guest.word(0x11000 + 136, @intCast(records));
            for (0..42) |word| guest.word(records + word * 4, @intCast(pass * 100 + word + 1));
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var output: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x13000, &output);
            for (0..4) |word| try std.testing.expectEqual(@as(u32, @intCast(pass * 100 + word + 1)), std.mem.readInt(u32, output[word * 4 ..][0..4], .little));
        }
        guest.word(0x11000 + 152, 2);
        try std.testing.expectError(error.InvalidStorageDescriptor, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 }));
        guest.word(0x11000 + 152, 1);
        // Use another program address so the immutable program cache is valid.
        code[0x3b54 / 4] |= 168;
        for (code, 0..) |word, index| guest.word(0x5000 + index * 4, word);
        try state.writeRegister(.shader, 0x20c, 0x50);
        try std.testing.expectError(error.GuestMemoryReadFailed, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 }));
    }
    std.debug.print("Scene FLAT snapshots passed: nested descriptor walk, carry-out address chain, relocated records, count bounds and live unmapped-read rejection\n", .{});
}

const FragmentShadowProbeShape = struct {
    extract_pc: usize,
    extract: u32,
    source_sgpr: u8,
    index_sgpr: u8,
    index_vgpr: u8,
    cube_pc: usize,
    cube_sources: u32,
    multiply_pc: usize,
    multiply: [3]u32,
    load_pc: usize,
    read_pc: usize,
    read_sources: u32,
};

fn runFragmentShadowPointerProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    for ([_]FragmentShadowProbeShape{
        .{ .extract_pc = 0x1194, .extract = 0x943bff04, .source_sgpr = 4, .index_sgpr = 59, .index_vgpr = 47, .cube_pc = 0x1288, .cube_sources = 0x04060500, .multiply_pc = 0x129c, .multiply = .{ 0xd5690033, 0x00025eff, 116 }, .load_pc = 0x12a8, .read_pc = 0x12c0, .read_sources = 0x006a0033 },
        // Captured material variants first used after the heroine lifts her
        // head. Their signed index moves through different SGPR/VGPR pairs.
        .{ .extract_pc = 0x3334, .extract = 0x9457ff51, .source_sgpr = 81, .index_sgpr = 87, .index_vgpr = 96, .cube_pc = 0x343c, .cube_sources = 0x040a0300, .multiply_pc = 0x3450, .multiply = .{ 0xd5690063, 0x0002c0ff, 116 }, .load_pc = 0x345c, .read_pc = 0x3474, .read_sources = 0x006a0063 },
        .{ .extract_pc = 0x3474, .extract = 0x9402ff0c, .source_sgpr = 12, .index_sgpr = 2, .index_vgpr = 88, .cube_pc = 0x3664, .cube_sources = 0x040a0300, .multiply_pc = 0x3678, .multiply = .{ 0xd569005c, 0x0002b0ff, 116 }, .load_pc = 0x3684, .read_pc = 0x369c, .read_sources = 0x006a005c },
    }) |shape| try runFragmentShadowPointerCase(allocator, &renderer, shape);
}

fn runFragmentShadowPointerCase(allocator: std.mem.Allocator, renderer: *vulkan.Renderer, shape: FragmentShadowProbeShape) !void {
    var guest = SizedGuestMemory(512 * 1024){};
    const vertex = [_]u32{
        vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
        vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
        vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
        0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
        0xf800_08cf,     0x0807_0605,      0xbf81_0000,
    };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    const code = try allocator.alloc(u32, (shape.read_pc + 20) / 4);
    defer allocator.free(code);
    @memset(code, 0xbf800000);
    code[0] = sop1(3, shape.source_sgpr, 4);
    const Site = struct { pc: usize, words: []const u32 };
    for ([_]Site{
        .{ .pc = shape.extract_pc, .words = &.{ shape.extract, 0x00080010 } },
        // Keep the real signed-index and CUBEID sites. The test supplies the
        // face explicitly so both ends of the recorded window are exercised.
        .{ .pc = shape.cube_pc - 4, .words = &.{0xbf820002} },
        .{ .pc = shape.cube_pc, .words = &.{ 0xd5440000, shape.cube_sources } },
        .{ .pc = shape.cube_pc + 8, .words = &.{vop1(1, 1, 6)} },
        .{ .pc = shape.cube_pc + 12, .words = &.{vop2Source(0x25, shape.index_vgpr, shape.index_sgpr, 1)} },
        .{ .pc = shape.multiply_pc, .words = &shape.multiply },
        .{ .pc = shape.load_pc, .words = &.{ 0xf4041a80, 0xfa000040 } },
        .{ .pc = shape.read_pc, .words = &.{ 0xdc3887b8, shape.read_sources } },
        .{ .pc = shape.read_pc + 8, .words = &.{ 0xf800080f, 0x03020100, 0xbf810000 } },
    }) |site| @memcpy(code[site.pc / 4 ..][0..site.words.len], site.words);
    // Longer material programs must not overlap the color target at 0x4000.
    for (code, 0..) |word, i| guest.word(0x50000 + i * 4, word);
    var state = gpu.State{};
    const pixel = gpu.resources.ShaderStage.pixel;
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), 7);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, pixel.programRegisterBase(), 0x500);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 3, 8 << 1);
    try state.writeRegister(.shader, pixel.userDataBase(), 0x10000);
    try state.writeRegister(.context, 0x318, 0x40);
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
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    const stream = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
    for (0..2) |pass| {
        const base: u32 = @intCast(0x18000 + pass * 0x8000);
        guest.word(0x10040, base);
        for ([_][2]u32{ .{ 0, 0 }, .{ 127, 5 } }) |selection| {
            const red: f32 = if (pass == 0) 0.25 else 0.75;
            const values = [_]f32{ red, 0.5, 1.0, 1.0 };
            for (values, 0..) |value, i| guest.word(base + 1976 + (selection[0] + selection[1]) * 116 + i * 4, @bitCast(value));
            try state.writeRegister(.shader, pixel.userDataBase() + 4, selection[0] << 16);
            try state.writeRegister(.shader, pixel.userDataBase() + 6, selection[1]);
            _ = try executor.execute(&stream);
            if (renderer.last_draw_error) |err| return err;
            try renderer.flushPendingGuestWrites();
            const center = guest.bytes[0x4000 + (4 * 8 + 4) * 4 ..][0..4];
            const expected = [_]u8{ if (pass == 0) 64 else 191, 128, 255, 255 };
            for (center, expected) |actual, wanted|
                try std.testing.expect(@abs(@as(i16, actual) - wanted) <= 1);
        }
    }
    try state.writeRegister(.shader, pixel.userDataBase() + 4, 128 << 16);
    try state.writeRegister(.shader, pixel.userDataBase() + 6, 0);
    _ = try executor.execute(&stream);
    try std.testing.expectEqual(@as(?anyerror, error.GuestMemoryReadFailed), renderer.last_draw_error);
    std.debug.print("fragment shadow records pc=0x{x} passed: rendered RGBA, live relocation, signed index, cube face range and unmapped-read rejection\n", .{shape.read_pc});
}

fn runShadowRecordPointerProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var code: [0x4bbc / 4]u32 = @splat(0xbf80_0000);
    code[0] = vop1(1, 74, 2); // packed signed byte index
    code[1] = vop1(1, 52, 3); // selected cube face
    const Site = struct { pc: usize, words: []const u32 };
    for ([_]Site{
        .{ .pc = 0x4a68, .words = &.{ 0xd5490041, 0x0221214a } },
        .{ .pc = 0x4a70, .words = &.{ 0xf4041a80, 0xfa001a38 } },
        .{ .pc = 0x4a88, .words = &.{ 0xd5690047, 0x000282ff, 0x00000074 } },
        .{ .pc = 0x4a94, .words = &.{0x7f480341} },
        .{ .pc = 0x4a9c, .words = &.{ 0xdc3087b4, 0x4c6a0047 } },
        .{ .pc = 0x4abc, .words = &.{ 0xdc3487e8, 0x476a0047 } },
        // Keep the captured CUBEID site, bypassing its coordinate math so
        // the probe can choose both ends of the valid face range explicitly.
        .{ .pc = 0x4b00, .words = &.{0xbf820006} },
        .{ .pc = 0x4b0c, .words = &.{ 0xd5440034, 0x051e6b34 } },
        .{ .pc = 0x4b1c, .words = &.{0x4b486941} },
        .{ .pc = 0x4b24, .words = &.{ 0xf4041a80, 0xfa001a38 } },
        .{ .pc = 0x4b2c, .words = &.{ 0xd5690034, 0x000348ff, 0x00000074 } },
        .{ .pc = 0x4b40, .words = &.{ 0xdc3887b8, 0x476a0034 } },
        .{ .pc = 0x4b48, .words = &.{ 0xdc3887a8, 0x4b6a0034 } },
        .{ .pc = 0x4b74, .words = &.{ 0xdc388798, 0x476a0034 } },
        .{ .pc = 0x4ba0, .words = &.{ 0xdc388788, 0x476a0034 } },
    }) |site| @memcpy(code[site.pc / 4 ..][0..site.words.len], site.words);
    code[0x4ba8 / 4] = vop1(1, 0, 128);
    code[0x4bac / 4] = mubuf(0x1e, 0, 71, 0, 4)[0];
    code[0x4bb0 / 4] = mubuf(0x1e, 0, 71, 0, 4)[1];
    code[0x4bb8 / 4] = 0xbf810000;
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x10000, 0, 0, 0, 0x1f000, 16 << 16, 1, (20 << 12) | 0xfac }, 0..) |word, i|
        try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
    for (0..2) |pass| {
        const base: u32 = @intCast(0x14000 + pass * 0x4000);
        guest.word(0x10000 + 6712, base);
        for (0..133) |record| for (0..4) |component|
            guest.word(base + 1928 + record * 116 + component * 4, @intCast(0xa0000000 + pass * 0x10000 + record * 100 + component));
        for ([_][2]u32{ .{ 0, 0 }, .{ 127, 5 } }) |selection| {
            try state.writeRegister(.shader, 0x242, selection[0] << 16);
            try state.writeRegister(.shader, 0x243, selection[1]);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var output: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x1f000, &output);
            for (0..4) |component| try std.testing.expectEqual(@as(u32, @intCast(0xa0000000 + pass * 0x10000 + (selection[0] + selection[1]) * 100 + component)), std.mem.readInt(u32, output[component * 4 ..][0..4], .little));
        }
    }
    try state.writeRegister(.shader, 0x242, 128 << 16);
    try state.writeRegister(.shader, 0x243, 0);
    try std.testing.expectError(error.GuestMemoryReadFailed, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 }));
    std.debug.print("Shadow FLAT records passed: VCC base, signed byte index, cube-face extent, relocation and active unmapped-page rejection\n", .{});
}

fn runSceneBitsetPointerProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = SizedGuestMemory(512 * 1024){};
    _ = renderer.dcbBackend(guest.interface());
    // Preserve the real pointer/stride extraction sites while selecting the
    // level and word through user data. The backend discovers every bitset.
    var code: [0x1e8 / 4]u32 = @splat(0xbf80_0000);
    code[0] = vop1(1, 0, 2);
    code[1] = vop1(1, 17, 3);
    for ([_]u32{ 0xdc34_8038, 0x0000_0000 }, 0..) |word, i| code[0x15c / 4 + i] = word;
    for ([_]u32{ 0xd70f_6a00, 0x0002_2300, 0x5002_02f9, 0x0c86_0680, 0xdc30_8000, 0x007d_0000 }, 0..) |word, i| code[0x1c0 / 4 + i] = word;
    code[0x1d8 / 4] = vop1(1, 2, 128);
    code[0x1dc / 4] = mubuf(0x1c, 0, 0, 2, 4)[0];
    code[0x1e0 / 4] = mubuf(0x1c, 0, 0, 2, 4)[1];
    code[0x1e4 / 4] = 0xbf81_0000;
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x10000, 0, 0, 0, 0x13000, 4 << 16, 1, 0x5204 }, 0..) |word, i|
        try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
    for (0..2) |pass| {
        for (0..9) |level| {
            const count = @max(@as(u32, 1), (@as(u32, 1) << @as(u5, @intCast(level * 2))) / 32);
            const address = 0x20000 + level * 0x3000 + pass * 0x20000;
            for ([_]u32{ @intCast(address), 4 << 16, count, 0x5204 }, 0..) |word, i|
                guest.word(0x10038 + level * 16 + i * 4, word);
            for (0..count) |i| guest.word(address + i * 4, @intCast(0xa0000000 + pass * 0x10000 + level * 0x1000 + i));
        }
        for ([_]u32{ 0, 3, 8 }) |level| {
            const count = @max(@as(u32, 1), (@as(u32, 1) << @as(u5, @intCast(level * 2))) / 32);
            try state.writeRegister(.shader, 0x242, level * 16);
            try state.writeRegister(.shader, 0x243, (count - 1) * 4);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var output: [4]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x13000, &output);
            try std.testing.expectEqual(@as(u32, @intCast(0xa0000000 + pass * 0x10000 + level * 0x1000 + count - 1)), std.mem.readInt(u32, &output, .little));
        }
    }
    guest.word(0x10038 + 8 * 16 + 8, 2049);
    try std.testing.expectError(error.InvalidStorageDescriptor, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 }));
    guest.word(0x10038 + 8 * 16 + 8, 2048);
    try state.writeRegister(.shader, 0x243, 2048 * 4);
    try std.testing.expectError(error.GuestMemoryReadFailed, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 }));
    std.debug.print("Scene bitset FLAT snapshots passed: runtime levels, stride extraction, last valid words, relocation, descriptor bounds and unmapped-read rejection\n", .{});
}

fn runBufferTableProbe(allocator: std.mem.Allocator) !void {
    try runBufferLookupProbe(allocator);
    try runBufferTableCase(allocator, false);
    try runBufferTableCase(allocator, true);
}

fn runBufferLookupProbe(allocator: std.mem.Allocator) !void {
    const lookup = gpu.shader_analysis.SpirvBufferLookup;
    const candidates = 128;
    const rows = candidates + 4;
    const capacity = comptime lookup.capacity(candidates);
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 20), 0xb814_0010, // group index and byte offset into the V# table
        0xf428_0104, 20 << 25, // s_buffer_load_dwordx4 s4, V#s8, s20
        vop2Source(0x1b, 1, 131, 0), // source element = group & 3
        mubuf(0x0c, 0, 5, 1, 4)[0],
        mubuf(0x0c, 0, 5, 1, 4)[1],
        mubuf(0x1c, 0, 5, 0, 12)[0],
        mubuf(0x1c, 0, 5, 0, 12)[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
    defer analysis.deinit(allocator);
    var bindings: [candidates + 2]gpu.ShaderSpirvStorageBufferBinding = undefined;
    bindings[0] = .{ .resource_sgpr = 8, .descriptor_index = 0 };
    bindings[1] = .{ .resource_sgpr = 12, .descriptor_index = 3, .stride = 4 };
    for (bindings[2..], 0..) |*binding, i| binding.* = .{
        .resource_sgpr = 4,
        .descriptor_index = @intCast(1 + i % 2),
        .stride = 4,
        .candidate_words = .{ @intCast(0x2000 + i * 256), 0x40000, @intCast(2 + i % 2), 0x5204 },
        .lookup = .{ .descriptor_index = 4, .word_offset = 0, .mask = @intCast(capacity - 1), .probes = @intCast(capacity) },
    };
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .wave32 = true,
        .compute_inputs = .{ .workgroup_id_sgprs = .{ 20, null, null } },
        .storage_buffers = &bindings,
    });
    defer module.deinit(allocator);
    var table: [capacity * lookup.entry_words]u32 = undefined;
    for (0..2) |pass| {
        @memset(&table, 0);
        for (bindings[2..], 0..) |binding, i| {
            var words = binding.candidate_words.?;
            for (&words, 0..) |*word, component| word.* ^= @as(u32, @intCast(pass)) << @intCast(20 + component);
            lookup.insert(&table, words, binding.descriptor_index);
            for (words, 0..) |word, component| guest.word(0x10000 + i * 16 + component * 4, word);
        }
        for (0..4) |mismatch| {
            for (0..4) |component| {
                var word = std.mem.readInt(u32, guest.bytes[0x10000 + component * 4 ..][0..4], .little);
                if (component == mismatch) word ^= 0x80000000;
                guest.word(0x10000 + (candidates + mismatch) * 16 + component * 4, word);
            }
        }
        for (table, 0..) |word, i| guest.word(0x14000 + i * 4, word);
        for (0..3) |i| {
            guest.word(0x12000 + i * 4, @intCast(100 + i + pass * 1000));
            guest.word(0x13000 + i * 4, @intCast(200 + i + pass * 1000));
        }
        for (0..rows) |i| guest.word(0x16000 + i * 4, 0xcccccccc);
        for ([_][3]u64{ .{ 0, 0x10000, rows * 16 }, .{ 1, 0x12000, 8 }, .{ 2, 0x13000, 12 }, .{ 3, 0x16000, rows * 4 }, .{ 4, 0x14000, table.len * 4 } }) |buffer|
            _ = try renderer.stageGuestStorageBufferAt(@intCast(buffer[0]), buffer[1], @intCast(buffer[2]));
        _ = try renderer.dispatchSpirv(module.words, .{ rows, 1, 1 });
        var output: [rows * 4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x16000, &output);
        for (0..rows) |i| {
            const valid = i < candidates and i % 4 < 2 + i % 2;
            const expected: u32 = if (valid) @intCast(100 + (i % 2) * 100 + i % 4 + pass * 1000) else 0;
            try std.testing.expectEqual(expected, std.mem.readInt(u32, output[i * 4 ..][0..4], .little));
        }
    }
    std.debug.print("runtime buffer hash lookup passed: 128 colliding candidates, four-word misses, unequal bounds and table relocation\n", .{});
}

fn runBufferTableCase(allocator: std.mem.Allocator, large: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 16), // preserve group index before loading the selected V#
        (0x1b << 25) | (1 << 17) | 129, // v1 = group & 1
        0x7d84_0280, // compare v1 == 0
        vop1(1, 2, 128),
        (1 << 25) | (3 << 17) | (2 << 9) | 129, // select 1 or 0
        vop1(2, 107, 259), // first active lane's choice -> VCC_HI
        0x8000_0000 | (0x31 << 23) | (107 << 16) | (160 << 8) | 107,
        0xf408_0100,                 107 << 25, // s4:s7 = *(SRT + 32 + choice * 16)
        vop1(1, 4, 255),             100,
        vop2(0x25, 4, 0, 4),         mubuf(0x1c, 0, 4, 0, 4)[0],
        mubuf(0x1c, 0, 4, 0, 4)[1],  mubuf(0x0c, 0, 5, 0, 4)[0],
        mubuf(0x0c, 0, 5, 0, 4)[1],  mubuf(0x1c, 0, 5, 0, 12)[0],
        mubuf(0x1c, 0, 5, 0, 12)[1], 0xbf81_0000,
    };
    var expanded: std.ArrayList(u32) = .empty;
    defer expanded.deinit(allocator);
    try expanded.appendSlice(allocator, code[0 .. code.len - 3]);
    if (large) for (0..40) |_| try expanded.appendSlice(allocator, &mubuf(0x0c, 0, 5, 0, 4));
    try expanded.appendSlice(allocator, code[code.len - 3 ..]);
    for (expanded.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, (16 << 1) | (1 << 7));
    try state.writeRegister(.shader, 0x240, 0x1000);
    try state.writeRegister(.shader, 0x241, 0);
    for ([_]u32{ 0x8000, 4 << 16, 8, 0x5204 }, 0..) |word, i| try state.writeRegister(.shader, 0x24c + @as(u32, @intCast(i)), word);
    for (0..2) |pass| {
        const first: u32 = 0x4000 + @as(u32, @intCast(pass)) * 0x1000;
        const second: u32 = 0x6000 + @as(u32, @intCast(pass)) * 0x1000;
        for ([_]u32{ first, 4 << 16, 4, 0x5204, second, 4 << 16, 6, 0x5204 }, 0..) |word, i| guest.word(0x1020 + i * 4, word);
        for (0..8) |i| {
            guest.word(first + i * 4, 0xdeadbeef);
            guest.word(second + i * 4, 0xdeadbeef);
            guest.word(0x8000 + i * 4, 0xcccccccc);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 8, 1, 1 });
        try renderer.flushPendingGuestWrites();
        for (0..8) |i| {
            const valid = if (i % 2 == 0) i < 4 else i < 6;
            const expected: u32 = if (valid) @intCast(100 + i) else 0;
            try std.testing.expectEqual(expected, std.mem.readInt(u32, guest.bytes[0x8000 + i * 4 ..][0..4], .little));
            try std.testing.expectEqual(if (i % 2 == 0 and i < 4) @as(u32, @intCast(100 + i)) else 0xdeadbeef, std.mem.readInt(u32, guest.bytes[first + i * 4 ..][0..4], .little));
            try std.testing.expectEqual(if (i % 2 == 1 and i < 6) @as(u32, @intCast(100 + i)) else 0xdeadbeef, std.mem.readInt(u32, guest.bytes[second + i * 4 ..][0..4], .little));
        }
    }
    if (large) {
        try std.testing.expectEqual(@as(u64, 1), renderer.pipeline_cache_misses);
        try std.testing.expectEqual(@as(u64, 1), renderer.pipeline_cache_hits);
    }
    std.debug.print("buffer table selection passed (large={any}): active-lane index, VCC_HI offset, runtime V# reads/writes, unequal bounds, untouched neighbours and relocation\n", .{large});
}

fn runVectorBufferAddressProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    for ([_]bool{ false, true }) |swizzled| {
        for ([_]u32{ 0, 0xffff_fff8 }) |offset| {
            const load = mubuf(0x0e, 0, 0, 0, 0);
            const code = [_]u32{
                vop1(1, 0, 8),              vop1(1, 4, 8),
                load[0],                    (load[1] & 0x00ff_ffff) | (12 << 24),
                mubuf(0x1e, 0, 0, 4, 4)[0], mubuf(0x1e, 0, 0, 4, 4)[1],
                0xbf81_0000,
            };
            for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
            var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
            defer analysis.deinit(allocator);
            var module = try analysis.translateSpirv(allocator, .{
                .stage = .compute,
                .compute_inputs = .{ .workgroup_id_sgprs = .{ 8, null, null } },
                .scalar_registers = &.{.{ .register = 12, .value = offset }},
                .storage_buffers = &.{
                    .{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 16, .swizzled = swizzled },
                    .{ .resource_sgpr = 4, .descriptor_index = 1, .stride = 16 },
                },
            });
            defer module.deinit(allocator);
            for ([_]usize{ 200, 40 }) |extent| {
                for (0..64) |i| guest.word(0x10000 + i * 4, @as(u32, @intCast(i)) * 101 + 7);
                @memset(guest.bytes[0x11000..][0..128], 0xa5);
                _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, extent);
                _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 128);
                _ = try renderer.dispatchSpirv(module.words, .{ 8, 1, 1 });
                var output: [128]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(0x11000, &output);
                for (0..8) |group| for (0..4) |component| {
                    const element: u32 = @intCast(if (swizzled) component * 32 + group * 4 else group * 16 + component * 4);
                    const address = element +% offset;
                    const expected: u32 = if (address < extent) address / 4 * 101 + 7 else 0;
                    const actual = std.mem.readInt(u32, output[group * 16 + component * 4 ..][0..4], .little);
                    try std.testing.expectEqual(expected, actual);
                };
            }
        }
    }
    std.debug.print("vector buffer addresses passed: overlapping destination/index, linear and swizzled loads, offset wrap and shrinking live bounds\n", .{});
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

fn runIndexedImageProbe(allocator: std.mem.Allocator) !void {
    for (0..6) |case| {
        const wrapping = case % 2;
        const index_register: u32 = switch (case / 2) {
            0 => 20,
            1 => 106,
            else => 107,
        };
        const offset_register: u32 = if (case < 2) 20 else 106;
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        const guest = try allocator.create(SizedGuestMemory(512 * 1024));
        defer allocator.destroy(guest);
        guest.* = .{};
        _ = renderer.dcbBackend(guest.interface());
        const records: u32 = 0x10000 + @as(u32, @intCast(wrapping)) * 0x1000;
        const textures: u32 = 0x48000 + @as(u32, @intCast(wrapping)) * 0x1000;
        const code = [_]u32{
            vop1(1, 1, 28),
            0xbf06_851c, // workgroup 5 reads beyond the material table
            0x8514_1cff,
            1754,
            0x8014_ff14,                                            if (wrapping == 0) 0 else 0x0f72_c235, // 116 * wrapping index == 4 mod 2^32
            0x9300_ff14 | (offset_register << 16),                  116,
            0xf420_0004 | (index_register << 6),                    (offset_register << 25) | 60,
            // Material indices may occupy either VCC word independently.
            0x8f00_8500 | (offset_register << 16) | index_register,
            0xf42c_000c,                 offset_register << 25, // T#s0 = global[V#s24][index << 5]
            vop1(1, 2, 255),             0x3e80_0000,
            vop1(1, 3, 255),             0x3e80_0000,
            vop1(1, 4, 255),             0x3f40_0000,
            0xf09c_0112,                 0x0080_0202,
            0x0403,                      mubuf(0x1c, 0, 2, 1, 12)[0],
            mubuf(0x1c, 0, 2, 1, 12)[1], 0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        // An unbounded stride-116 product reaches over 50,000 word windows;
        // only their referenced T# entries belong in the Vulkan table.
        const indices = [_]u32{ 2, 1, 0x0800_0003, 4, 0xffff_ffff };
        for (indices, 0..) |value, index| guest.word(records + index * 116 + 60 + wrapping * 4, value);
        for (0..4) |index| {
            const address: u32 = if (index == 0) 0xa000 else if (index == 1) 0x9000 else 0x8000;
            var descriptor = sampledImageDescriptorWords(address, 1, 1);
            if (index == 1) {
                descriptor[3] = (descriptor[3] & 0x0fff_ffff) | 0xa000_0000;
                descriptor[4] = 1;
            } else if (index == 3) descriptor[3] = (descriptor[3] & ~@as(u32, 7)) | 6;
            for (descriptor, 0..) |word, component| guest.word(textures + index * 32 + component * 4, word);
            const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
            const surface = try layout.base();
            for (0..if (index == 1) @as(usize, 2) else 1) |z| {
                const pixel = address + @as(usize, @intCast(try surface.sourceByteOffset(0, 0, @intCast(z), 0)));
                guest.word(pixel, if (index == 0) 0xff00_0020 else if (index != 1) 0xff80_00ff else if (z == 0) 0xff00_00aa else 0xff00_0040);
            }
        }
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, 1);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, (28 << 1) | (1 << 7));
        var userdata: [28]u32 = @splat(0);
        @memcpy(userdata[8..12], &[_]u32{ records, 116 << 16, 1754, 0 });
        @memcpy(userdata[12..16], &[_]u32{ 0x50000, 4 << 16, 6, 0 });
        @memcpy(userdata[24..28], &[_]u32{ textures, 32 << 16, 4, 0 });
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 6, 1, 1 });
        var output: [24]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x50000, &output);
        for ([_]f32{ 1, 64.0 / 255.0, 128.0 / 255.0, 0, 0, 32.0 / 255.0 }, 0..) |expected, index| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
    }
    std.debug.print("indexed images passed: material-to-global tables, SGPR/VCC_LO/VCC_HI indices, large record scan, wrapping multiply/shift, mixed views, exact aliases and both bounds\n", .{});
}

fn runInactiveImageTableProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 28),
        vop1(2, 106, 256),
        0x936a_ff6a, 96, // waterfall index * 96
        0xf42c_000c,     106 << 25, // T#s0 = V#s24[index * 96]
        vop1(1, 2, 255), 0x3e800000,
        vop1(1, 3, 255), 0x3e800000,
        vop1(1, 4, 255), 0x3f000000,
        sop1(4, 22, 126), // save EXEC
        0x7da4_0014, // CMPX EQ s20, v0
        0xf09c_010a,
        0x0080_0402,
        3,
        sop1(4, 126, 22),
        mubuf(0x1c, 0, 4, 0, 12)[0],
        mubuf(0x1c, 0, 4, 0, 12)[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, (28 << 1) | (1 << 7));
    var userdata: [28]u32 = @splat(0);
    @memcpy(userdata[12..16], &[_]u32{ 0x13000, 4 << 16, 3, 0 });
    for (0..2) |pass| {
        const table: u32 = @intCast(0x10000 + pass * 0x1000);
        @memcpy(userdata[24..28], &[_]u32{ table, 96 << 16, 2, 0 });
        // An unused record holds non-descriptor data. It must not cancel
        // work done by other lanes, or become a silently substituted image.
        guest.word(table + 96 + 12, 0x38530000);
        for ([_]u32{ 3, 0, 2, 1, 0 }) |selected| {
            userdata[20] = selected;
            for (userdata, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
            if (selected == 1) {
                try std.testing.expectError(error.UnsupportedSampledImage, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 3, 1, 1 }));
                continue;
            }
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 3, 1, 1 });
            var output: [12]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x13000, &output);
            for (0..3) |i| {
                const actual: f32 = @bitCast(std.mem.readInt(u32, output[i * 4 ..][0..4], .little));
                try std.testing.expectEqual(@as(f32, if (i == selected) 0 else 0.5), actual);
            }
        }
    }
    std.debug.print("inactive image tables passed: masked invalid records, active null and OOB tuples, active invalid rejection, relocation and fault reset\n", .{});
}

fn runShiftedImageProbe(allocator: std.mem.Allocator) !void {
    for ([_]u32{ 106, 107 }) |selector| for ([_]u32{ 5, 37 }) |shift| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const code = [_]u32{
            vop1(1, 0, 28), // retain group/output index
            vop1(1, 1, 255),
            0x08000000,
            vop2(0x25, 1, 0, 1), // high bits wrap out of index << 5
            vop1(2, @intCast(selector), 257), // dynamic first active lane -> VCC word
            0x8f00_ff00 | (selector << 16) | selector,
            shift,
            0xf42c_000c,                 selector << 25, // T#s0 = V#s24[index << 5]
            vop1(1, 2, 255),             0x3e800000,
            vop1(1, 3, 255),             0x3e800000,
            0xf09c_010a,                 0x0080_0202,
            3,                           mubuf(0x1c, 0, 2, 0, 12)[0],
            mubuf(0x1c, 0, 2, 0, 12)[1], 0xbf81_0000,
        };
        for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, 1);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, (28 << 1) | (1 << 7));
        var userdata: [28]u32 = @splat(0);
        @memcpy(userdata[12..16], &[_]u32{ 0x13000, 4 << 16, 4, 0 });
        for (0..2) |pass| {
            const table: u32 = @intCast(0x10000 + pass * 0x1000);
            @memcpy(userdata[24..28], &[_]u32{ table, 32 << 16, 3, 0 });
            for (userdata, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
            for (0..2) |entry| {
                const address: u32 = @intCast(0x8000 + ((entry + pass) % 2) * 0x1000);
                const descriptor = sampledImageDescriptorWords(address, 1, 1);
                for (descriptor, 0..) |word, i| guest.word(table + entry * 32 + i * 4, word);
                guest.word(address, if (address == 0x8000) 0xff0000ff else 0xff000040);
            }
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 4, 1, 1 });
            var output: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x13000, &output);
            for ([_]f32{ if (pass == 0) 1 else 64.0 / 255.0, if (pass == 0) 64.0 / 255.0 else 1, 0, 0 }, 0..) |expected, i| {
                const actual: f32 = @bitCast(std.mem.readInt(u32, output[i * 4 ..][0..4], .little));
                try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
            }
        }
    };
    std.debug.print("shifted sampled images passed: active-lane VCC selection, masked shift amount, 32-bit wrap, relocated tables, null descriptors and bounds\n", .{});
}

fn runNestedImageProbe(allocator: std.mem.Allocator) !void {
    try runNestedImageCase(allocator, false, false);
    try runNestedImageCase(allocator, true, false);
    try runNestedImageCase(allocator, true, true);
    std.debug.print("nested sampled images passed: record pointers, bounded lane selection, reused table SGPRs, runtime T#/S# loads, null bounds and relocated object pages\n", .{});
}

fn runNestedImageCase(allocator: std.mem.Allocator, bounded: bool, reuse_table: bool) !void {
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
        0xf424_000c,                                        106 << 25, // pointer = s_buffer_load_dwordx2 s0, V#s24, vcc_lo
        // The original V# remains relevant to the pointer load even after
        // this SGPR window is reused before the texture operation.
        if (reuse_table) sop1(3, 24, 128) else 0xbf80_0000, if (reuse_table) sop1(3, 25, 128) else 0xbf80_0000,
        if (reuse_table) sop1(3, 26, 128) else 0xbf80_0000, if (reuse_table) sop1(3, 27, 128) else 0xbf80_0000,
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
    try runTypedIndexSelectionProbe(allocator, false);
}

fn runTypedIndexSelectionProbe(allocator: std.mem.Allocator, selection: bool) !void {
    for (0..@as(usize, if (selection) 16 else 28)) |case_index| {
        const format = ([_]u32{ 5, 6, 11, 12 })[case_index % 4];
        const mask_case = if (selection) 0 else case_index / 4;
        const gather = selection and case_index % 8 >= 4;
        const partial_selection = selection and case_index >= 8;
        const saved_after_fetch = mask_case == 1 or mask_case == 3;
        var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const code = [_]u32{
            vop1(1, 0, 28), vop1(1, 1, 128),
            if (selection) sop1(4, 32, 126) else if (mask_case == 4) sop1(0x24, 106, 128) else if (saved_after_fetch) 0xbf80_0000 else sop1(4, 106, 126), // preserve EXEC before fetching the index
            if (mask_case == 2) 0x7daa_0280 else 0xbf80_0000, // CMPX NE 0, v1 disables lanes
            if (mask_case == 2 or mask_case == 4) 0xbf88_0001 else 0xbf80_0000, // skip into the restore block
            0xbf80_0000,
            if (mask_case == 2 or mask_case == 4) sop1(4, 126, 106) else 0xbf80_0000,
            if (gather) 0xf11c_0108 else 0xf000_0108,
            if (gather) 0x0085_0f00 else 0x0005_0f00,
            if (selection) sop1(4, 106, 193) else 0xbf80_0000,
            if (selection) 0x0228_0080 | ((15 + @as(u32, @intCast(if (gather) case_index % 4 else 0))) << 9) else 0xbf80_0000,
            if (selection) 0x022a_2880 else 0xbf80_0000,
            if (selection and !partial_selection) vop1(1, 15, 277) else 0xbf80_0000,
            if (partial_selection) 0x7da4_0081 else if (saved_after_fetch) sop1(0x24, 106, 128) else 0xbf80_0000, // CMPX EQ 1, v0 / s_and_saveexec_b64 vcc, 0
            if (partial_selection or mask_case == 3) 0xbf88_0001 else 0xbf80_0000,
            if (partial_selection) vop1(1, 15, 128) else 0xbf80_0000, // replace only the selected lanes; others keep the fetched index
            if (partial_selection) sop1(4, 126, 32) else if (saved_after_fetch) sop1(4, 126, 106) else 0xbf80_0000, // restore lanes after the conditional
            if (mask_case == 3) sop1(0x24, 32, 193) else 0xbf80_0000, // another snapshot in the restored block
            sop1(4, 28, if (selection or mask_case == 3) 32 else 106),
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
        if (selection) {
            var other_field = sampledImageDescriptorWords(0xb000, 1, 1);
            other_field[3] = (other_field[3] & 0x0fff_ffff) | 0xc000_0000;
            for (other_field, 0..) |word, index| guest.word(0x11000 + 96 + index * 4, word);
        }
        var indices = sampledImageDescriptorWords(0xa000, if (gather) 1 else 6, 1);
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
        if (gather) guest.word(0xa000, 1);
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
            const selected_expected = if (partial_selection and index == 1) 1.0 else if (gather) 64.0 / 255.0 else expected;
            try std.testing.expectApproxEqAbs(selected_expected, actual, 0.00001);
        }
        try std.testing.expectEqual(@as(u64, if (gather) 3 else 2), renderer.texture_cache_misses);
    }
    std.debug.print("typed index images passed: UINT/SINT byte and short indices, negative bounds and decoy fields\n", .{});
}

const ImageLoopMode = enum { counted, uniform_limit, masked_pointer, masked_buffer };

fn runCountedImageLoopProbe(allocator: std.mem.Allocator, mode: ImageLoopMode) !void {
    const uniform_limit = mode != .counted;
    const masked = mode == .masked_pointer or mode == .masked_buffer;
    const record_stride: u32 = if (mode == .masked_buffer) 440 else 32;
    var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const counted_code = [_]u32{
        0xbe90_0380, // s_mov_b32 s16, 0
        vop1(1, 0, 128),
        vop1(1, 1, 128),
        0x8f6a_8510, // s_lshl_b32 VCC_LO, s16, 5
        0xf40c_0100, 0xd400_0000, // s_load_dwordx8 s4, s0, VCC_LO
        0xf000_0108,    0x0001_0200, // image_load v2, v0:v1, T#s4
        vop1(1, 4, 16), 0xe070_2000,
        0x8003_0204,
        0x8110_8110, // increment / signed bound / back edge
        0xbf04_8610,
        0xbf85_fff5,
        0xbf81_0000,
    };
    const uniform_code = [_]u32{
        0xbe90_0380, // zero-based counter s16
        0xf400_0440,     0xfa00_0100, // runtime limit s17 from root + 256
        vop1(1, 0, 128), vop1(1, 1, 128),
        0xbf04_1110, 0xbf84_000f, // while (s16 < s17), signed
        0x8f6a_8510, 0xf40c_0100,
        0xd400_0000, 0xf000_0108,
        0x0001_0200,
        0x97eb_ff10, 4096, // s_lshl2_add VCC_HI, s16, coefficient displacement
        0xf400_0480, 0xd600_0000, // coefficient s18 from another captured page
        0x1004_0412, // v_mul_f32 v2, s18, v2
        vop1(1, 4, 16),
        0xe070_2000,
        0x8003_0204,
        0x8110_8110,
        0xbf82_ffef,
        0xbf81_0000,
    };
    const masked_code = [_]u32{
        0xbe90_0380, // 0: counter s16 = 0
        0xf400_0440, 0xfa00_0100, // 1: limit s17 from root + 256
        0xbe98_047e, // 3: preserve EXEC in s24:s25
        0xf408_0500, 0xfa00_0110, // 4: table V# s20:s23 from root + 272
        vop1(1, 0, 128), vop1(1, 1, 128), // 6: coordinates
        0xbf0a_1110, // 8: s_cmp_lt_u32 s16, s17
        0xbf80_0000,
        0x859a_807e, // 10: s_cselect_b64 s26, EXEC, 0
        0xbeea_041a, // 11: VCC = selected mask
        0xbefe_041a, // 12: EXEC = selected mask
        0xbf86_0010, // 13: VCCZ -> word 30
        0x936a_ff10, record_stride, // 14: VCC_LO = counter * stride
        if (mode == .masked_buffer) 0xf42c_010a else 0xf40c_0100, 0xd400_0000, // 16: T# s4
        0xf000_0108, 0x0001_0200, // 18: image_load v2
        0x97eb_ff10, 4096, // 20: coefficient offset
        0xf400_0480, 0xd600_0000, // 22: coefficient s18
        0x1004_0412, // 24: multiply
        vop1(1, 4, 16), // 25: output index
        0xe070_2000, 0x8003_0204, // 26: output store
        0x8110_8110, // 28: increment
        0xbf82_ffea, // 29: back to word 8
        0xbefe_0418, // 30: restore EXEC
        0xbf81_0000,
    };
    const code: []const u32 = if (masked) &masked_code else if (uniform_limit) &uniform_code else &counted_code;
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    const limits = [_]u32{ 3, 1, 6 };
    for (0..@as(usize, if (uniform_limit) limits.len else 2)) |pass| {
        const table: u32 = if (pass == 1) 0x12fc0 else 0x10fc0;
        const limit: u32 = if (uniform_limit) limits[pass] else 6;
        const destination: u32 = 0x6000 + @as(u32, @intCast(pass)) * 256;
        // Invalid descriptors between material fields must never become
        // candidates once the counter's guard proves its reachable range.
        if (masked) @memset(guest.bytes[table..][0 .. 6 * record_stride], 0xcd);
        for (0..6) |index| {
            const texture = if (pass == 0) index else 5 - index;
            const address: u32 = 0x8000 + @as(u32, @intCast(texture)) * 256;
            var image = sampledImageDescriptorWords(address, 4, 4);
            image[1] = (image[1] & ~@as(u32, 0x1ff00000)) | (175 << 20); // BC4 UNORM
            for (image, 0..) |word, component| guest.word(table + index * record_stride + component * 4, word);
            guest.word(address, @intCast((texture + 1) * 20)); // all texels select the first endpoint
            guest.word(table + 4096 + index * 4, @bitCast(@as(f32, @floatFromInt(index + 1)) / 8.0));
        }
        if (pass == 1) @memset(guest.bytes[table + 2 * record_stride ..][0..32], 0);
        guest.word(table + 256, limit);
        if (masked) for ([_]u32{ table, record_stride << 16, 6, 0 }, 0..) |word, component|
            guest.word(table + 272 + component * 4, word);
        for (0..6) |index| guest.word(destination + index * 4, 0x42c6_0000); // 99.0, unwritten tail
        var userdata: [16]u32 = @splat(0);
        userdata[0] = table;
        @memcpy(userdata[12..16], &[_]u32{ destination, 4 << 16, 6, 0 });
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var output: [24]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &output);
        for (0..6) |index| {
            const texture = if (pass == 0) index else 5 - index;
            const coefficient: f32 = if (uniform_limit) @as(f32, @floatFromInt(index + 1)) / 8.0 else 1;
            const expected: f32 = if (index >= limit) 99.0 else if (pass == 1 and index == 2) 0 else coefficient * @as(f32, @floatFromInt((texture + 1) * 20)) / 255.0;
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 1.0 / 32767.0);
        }
    }
    std.debug.print("{s} image loop passed: BC4 images, dynamic SMEM offsets, page crossing and relocation\n", .{@tagName(mode)});
}

fn runHostImportProbe(allocator: std.mem.Allocator, retain: bool) !void {
    const Memory = struct {
        bytes: []u8,
        relocated: bool = false,
        relocated_output: bool = false,
        decline: bool = false,
        publications: usize = 0,
        var active_views: usize = 0;
        fn selfFrom(context: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(context.?));
        }
        fn offset(self: *@This(), address: u64) usize {
            if (address >= 0x40000 and address < 0x50000 and self.relocated_output) return @intCast(address + 0x60000);
            if (address >= 0x10000 and address < 0x20000 and self.relocated) return @intCast(address + 0x70000);
            if (address >= 0x50000 and address < 0x60000) return @intCast(address - 0x40000);
            return @intCast(address);
        }
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self = selfFrom(context);
            const at = self.offset(address);
            if (at > self.bytes.len or bytes.len > self.bytes.len - at) return false;
            @memcpy(bytes, self.bytes[at..][0..bytes.len]);
            return true;
        }
        fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
            const self = selfFrom(context);
            const at = self.offset(address);
            if (at > self.bytes.len or bytes.len > self.bytes.len - at) return false;
            @memcpy(self.bytes[at..][0..bytes.len], bytes);
            return true;
        }
        fn identity(context: ?*anyopaque, address: u64, size: usize) ?u64 {
            const self = selfFrom(context);
            const at = self.offset(address);
            if (self.decline or at % 4096 != 0 or at > self.bytes.len or size > self.bytes.len - at) return null;
            return at;
        }
        fn acquire(context: ?*anyopaque, address: u64, size: usize, expected: u64) ?vulkan.GuestMemory.HostMapping {
            const self = selfFrom(context);
            const at = identity(context, address, size) orelse return null;
            if (at != expected) return null;
            active_views += 1;
            return .{ .bytes = self.bytes[@intCast(at)..][0..std.mem.alignForward(usize, size, 4096)], .offset = 0, .identity = at, .release = release };
        }
        fn release(_: []u8) void {
            active_views -= 1;
        }
        fn publish(context: ?*anyopaque, _: u64, _: usize) bool {
            selfFrom(context).publications += 1;
            return true;
        }
        fn word(self: *@This(), address: u64, value: u32) void {
            std.mem.writeInt(u32, self.bytes[self.offset(address)..][0..4], value, .little);
        }
    };
    const bytes = try std.heap.page_allocator.alloc(u8, 12 * 1024 * 1024);
    defer std.heap.page_allocator.free(bytes);
    @memset(bytes, 0x5a);
    var guest = Memory{ .bytes = bytes };
    {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_host_import = true, .defer_small_storage_writes = true, .enable_timeline_scheduler = true });
        defer renderer.deinit();
        renderer.retain_clean_storage_buffers = retain;
        renderer.storage_buffer_cache_budget_bytes = 512 * 1024 * 1024;
        try std.testing.expect(renderer.host_import_properties != null);
        _ = renderer.dcbBackend(.{ .context = &guest, .read = Memory.read, .write = Memory.write, .host_source = .{ .context = &guest, .identity = Memory.identity, .acquire = Memory.acquire, .publish = Memory.publish } });
        const code = [_]u32{ vop1(1, 0, 8), 0xe030_1000, 0x8000_0100, 0xbf8c_0f70, 0xe070_1000, 0x8001_0100, 0xbf81_0000 };
        for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase(), 1);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 9 << 1);
        const userdata = [_]u32{ 0x10000, 4 << 16, 16384, 0, 0x40000, 4 << 16, 16384, 0, 65532 };
        for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
        for (0..5) |pass| {
            if (pass == 2) guest.relocated = true;
            const source: u32 = if (pass == 3) 0x50000 else 0x10000;
            const expected = 0x12340000 + @as(u32, @intCast(pass));
            guest.word(source + 65532, expected);
            try state.writeRegister(.shader, compute.userDataBase(), source);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            try renderer.flushPendingGuestWrites();
            try std.testing.expectEqual(expected, std.mem.readInt(u32, bytes[0x4fffc..][0..4], .little));
            for (bytes[0x40000..0x4fffc]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
            try std.testing.expectEqual(@as(u64, 0), renderer.frame_profile.storage_upload_bytes);
            try std.testing.expectEqual(@as(u64, 0), renderer.frame_profile.storage_readback_bytes);
        }
        try std.testing.expect(guest.publications >= 5);
        // Different guest aliases of the original source share one import.
        try std.testing.expectEqual(@as(usize, 3), Memory.active_views);
        // Remap a dirty output while its old allocation is still referenced by
        // submitted work. Retiring it must finish the old physical write and
        // leave the replacement pages untouched until their own dispatch.
        guest.word(0x1fffc, 0xabcdef01);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        guest.relocated_output = true;
        _ = try renderer.stageGuestStorageBufferAt(1, 0x40000, 65536);
        try std.testing.expectEqual(@as(u32, 0xabcdef01), std.mem.readInt(u32, bytes[0x4fffc..][0..4], .little));
        for (bytes[0xa0000..0xb0000]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
        guest.word(0x1fffc, 0xabcdef02);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0xabcdef02), std.mem.readInt(u32, bytes[0xafffc..][0..4], .little));
        try std.testing.expectEqual(@as(u64, 0), renderer.frame_profile.storage_upload_bytes);
        try std.testing.expectEqual(@as(u64, 0), renderer.frame_profile.storage_readback_bytes);
        // Declined imports must still use the normal coherent copy path.
        guest.decline = true;
        guest.word(0x10000 + 65532, 0x98765432);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0x98765432), std.mem.readInt(u32, bytes[0xafffc..][0..4], .little));
        try std.testing.expect(renderer.frame_profile.storage_upload_bytes >= 65536);
        guest.decline = false;
        for (0..132) |i| {
            _ = try renderer.stageGuestStorageBufferAt(0, 0x100000 + i * 65536, 65536);
        }
        // Cache pressure can retire idle imports, but buffers retaining a
        // memory object must keep its mapping alive. A full live pool falls
        // back to ordinary staging instead of releasing referenced pages.
        try std.testing.expectEqual(@as(usize, 128), Memory.active_views);
        try std.testing.expectEqual(@as(usize, 128), renderer.imported_allocations.items.len);
    }
    try std.testing.expectEqual(@as(usize, 0), Memory.active_views);
    std.debug.print("host import passed: native CPU edits, GPU partial writes, aliasing, VA remap, coherent publication, fallback and retained-view cleanup\n", .{});
}

fn runBufferContentCacheProbe(allocator: std.mem.Allocator, device_budget: usize) !void {
    try runBufferContentCacheSizeProbe(allocator, device_budget, 256);
    try runBufferContentCacheSizeProbe(allocator, device_budget, 4 * 1024 * 1024 + 256);
}

fn runBufferViewCoherenceProbe(allocator: std.mem.Allocator) !void {
    try runBufferViewCoherenceSizeProbe(allocator, 0);
    try runBufferViewCoherenceSizeProbe(allocator, 4 * 1024 * 1024);
}

fn runBufferViewCoherenceSizeProbe(allocator: std.mem.Allocator, comptime padding: u32) !void {
    const Memory = SizedGuestMemory(padding + 0x30000);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    for ([_]bool{ false, true }) |retain| {
        guest.* = .{};
        var renderer = try vulkan.Renderer.init(allocator, .{
            .enable_timeline_scheduler = true,
            .defer_small_storage_writes = padding == 0,
            .retain_clean_storage_buffers = retain,
        });
        defer renderer.deinit();
        var memory = guest.interface();
        memory.fingerprint = Memory.fingerprint;
        _ = renderer.dcbBackend(memory);
        const source = 0x10000;
        const output = padding + 0x20000;
        const read_code = [_]u32{
            vop1(1, 0, 8),
            0xe030_1000,
            0x8000_0100,
            0xbf8c_0f70,
            0xe070_0000,
            0x8001_0100,
            0xbf81_0000,
        };
        const write_code = [_]u32{
            vop1(1, 0, 8), vop1(1, 1, 9),
            0xe070_1000,   0x8000_0100,
            0xbf81_0000,
        };
        for (read_code, 0..) |word, i| guest.word(0x100 + i * 4, word);
        for (write_code, 0..) |word, i| guest.word(0x400 + i * 4, word);
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 10 << 1);
        const userdata = [_]u32{ source, 4 << 16, 32, 0, output, 4 << 16, 1, 0, 0, 0 };
        for (userdata, 0..) |word, i|
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
        guest.word(source, 0x0102_0304);
        // Keep both range sizes alive while alternating GPU authorship. A
        // narrower write must reach the wider reader without losing its tail.
        const steps = [_]struct { write: bool, bytes: u32, offset: u32, value: u32 }{
            .{ .write = false, .bytes = 128, .offset = 0, .value = 0x0102_0304 },
            .{ .write = true, .bytes = 64, .offset = 0, .value = 0xdead_beef },
            .{ .write = false, .bytes = 128, .offset = 0, .value = 0xdead_beef },
            .{ .write = true, .bytes = 128, .offset = 96, .value = 0xcafe_f00d },
            .{ .write = false, .bytes = 64, .offset = 0, .value = 0xdead_beef },
            .{ .write = true, .bytes = 64, .offset = 4, .value = 0xaabb_ccdd },
            .{ .write = false, .bytes = 128, .offset = 4, .value = 0xaabb_ccdd },
            .{ .write = false, .bytes = 128, .offset = 96, .value = 0xcafe_f00d },
        };
        for (steps, 0..) |step, index| {
            try state.writeRegister(.shader, compute.programRegisterBase(), if (step.write) 4 else 1);
            try state.writeRegister(.shader, compute.userDataBase() + 2, (padding + step.bytes) / 4);
            try state.writeRegister(.shader, compute.userDataBase() + 8, if (step.offset == 96) padding + step.offset else step.offset);
            try state.writeRegister(.shader, compute.userDataBase() + 9, step.value);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            if (!step.write) {
                var result: [4]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(output, &result);
                const actual = std.mem.readInt(u32, &result, .little);
                if (actual != step.value)
                    std.debug.print("buffer view padding={d} retain={any} step={d}: expected=0x{x} actual=0x{x}\n", .{ padding, retain, index, step.value, actual });
                try std.testing.expectEqual(step.value, actual);
            }
        }
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0xdead_beef), std.mem.readInt(u32, guest.bytes[source..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0xaabb_ccdd), std.mem.readInt(u32, guest.bytes[source + 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0xcafe_f00d), std.mem.readInt(u32, guest.bytes[source + padding + 96 ..][0..4], .little));
    }
    std.debug.print("buffer view coherence passed: GPU writes across {d}/{d}-byte views, preserved tail, both cache modes\n", .{ padding + 64, padding + 128 });
}

fn runBufferContentCacheSizeProbe(allocator: std.mem.Allocator, device_budget: usize, comptime size: usize) !void {
    const Memory = SizedGuestMemory(8 * 1024 * 1024);
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    const old_participants = gpu.parallel_copy.guest_copy_pool.participants.load(.acquire);
    defer {
        gpu.parallel_copy.guest_copy_pool.deinit();
        gpu.parallel_copy.guest_copy_pool.participants.store(old_participants, .release);
    }
    var renderer = try vulkan.Renderer.init(allocator, .{ .defer_small_storage_writes = true, .enable_timeline_scheduler = true, .device_storage_budget_bytes = device_budget });
    defer renderer.deinit();
    var memory = guest.interface();
    memory.fingerprint = Memory.fingerprint;
    _ = renderer.dcbBackend(memory);
    const source = 0x10000;
    const output = 0x500000;
    const offset: usize = @min(35000, size - 8);
    const code = [_]u32{
        vop1(1, 0, 8),
        0xe030_1000, 0x8000_0100, // load at v0 from source V#s0
        0xbf8c_0f70,
        0xe070_0000, 0x8001_0100, // store v1 to output V#s4
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    const write_code = [_]u32{
        vop1(1, 0, 8), vop1(1, 1, 255), 0x0bad_f00d,
        0xe070_1000, 0x8000_0100, // GPU overwrites the previously cached source
        0xbf81_0000,
    };
    for (write_code, 0..) |word, i| guest.word(0x400 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 9 << 1);
    const userdata = [_]u32{ source, 4 << 16, size / 4, 0, output, 4 << 16, 1, 0, offset };
    for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
    guest.word(source + offset, 0x1234_5678);
    var previous_uploads: u64 = 0;
    for (0..5) |pass| {
        gpu.parallel_copy.guest_copy_pool.participants.store(([_]u8{ 1, 4, 2, 4, 1 })[pass], .release);
        if (pass == 2) guest.word(source + offset, 0x8765_4321);
        // A native write outside the texel currently fetched must still
        // invalidate the full buffer; sparse content probes would miss it.
        if (pass == 3) guest.word(source + size - 4, 0xaabb_ccdd);
        if (pass == 4) try state.writeRegister(.shader, compute.userDataBase() + 8, size - 4);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var result: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(output, &result);
        const expected: u32 = if (pass < 2) 0x1234_5678 else if (pass < 4) 0x8765_4321 else 0xaabb_ccdd;
        try std.testing.expectEqual(expected, std.mem.readInt(u32, &result, .little));
        if (pass == 1 or pass == 4) try std.testing.expectEqual(previous_uploads, renderer.buffer_uploads);
        if (pass == 2 or pass == 3) try std.testing.expectEqual(previous_uploads + 1, renderer.buffer_uploads);
        previous_uploads = renderer.buffer_uploads;
    }
    try state.writeRegister(.shader, compute.programRegisterBase(), 4);
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    var result: [4]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(output, &result);
    try std.testing.expectEqual(@as(u32, 0x0bad_f00d), std.mem.readInt(u32, &result, .little));
    try renderer.flushPendingGuestWrites();
    renderer.guest_memory.?.fingerprint = null;
    guest.word(source + size - 4, 0x0102_0304);
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(output, &result);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), std.mem.readInt(u32, &result, .little));
    renderer.guest_memory.?.fingerprint = Memory.fingerprint;
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(output, &result);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), std.mem.readInt(u32, &result, .little));
    try renderer.flushPendingGuestWrites();
    // A clean cached input can still have readers queued on the GPU. An
    // unchanged lookup must preserve those commands without another upload;
    // a native change must finish the old readers before replacing their data.
    const queued_code = [_]u32{
        0xe030_0000, 0x8002_0000, // buffer_load_dword v0, s8:s11
        0xe070_0000, 0x8003_0000, // buffer_store_dword v0, s12:s15
        0xbf81_0000,
    };
    for (queued_code, 0..) |word, i| guest.word(0x500 + i * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = guest, .read_fn = Memory.read }, 0x500, 16);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 1, 1, 1 },
        .storage_buffers = &.{
            .{ .resource_sgpr = 8, .descriptor_index = 0, .extent_bytes = size },
            .{ .resource_sgpr = 12, .descriptor_index = 1, .extent_bytes = 16 },
        },
    });
    defer module.deinit(allocator);
    guest.word(source, 0x1122_3344);
    _ = try renderer.stageGuestStorageBufferAt(0, source, size);
    _ = try renderer.stageGuestStorageBufferAt(1, output, 16);
    renderer.draw_batch_active = true;
    defer renderer.draw_batch_active = false;
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    try std.testing.expect(renderer.pending_command_buffers.items.len != 0);
    // Mirror normal draw/dispatch preparation: use a fresh descriptor set
    // while the preceding set remains referenced by an executable command.
    const next_set = renderer.descriptor_sets[renderer.descriptor_sets.len - 1];
    try std.testing.expect(next_set != renderer.descriptor_set);
    renderer.descriptor_set = next_set;
    const queued_uploads = renderer.buffer_uploads;
    _ = try renderer.stageGuestStorageBufferAt(0, source, size);
    try std.testing.expectEqual(queued_uploads, renderer.buffer_uploads);
    try std.testing.expect(renderer.pending_command_buffers.items.len != 0);
    guest.word(source, 0xaabb_ccdd);
    _ = try renderer.stageGuestStorageBufferAt(0, source, size);
    try std.testing.expectEqual(queued_uploads + 1, renderer.buffer_uploads);
    var queued_result: [16]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(output, &queued_result);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), std.mem.readInt(u32, queued_result[0..4], .little));
    _ = try renderer.stageGuestStorageBufferAt(1, output, 16);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(output, &queued_result);
    try std.testing.expectEqual(@as(u32, 0xaabb_ccdd), std.mem.readInt(u32, queued_result[0..4], .little));
    std.debug.print("buffer content cache passed ({d} bytes): unchanged reuse, full-range native writes, GPU overwrites, unavailable-fingerprint fallback and queued readers\n", .{size});
}

fn runParallelCopyProbe(allocator: std.mem.Allocator) !void {
    const size = 16 * 1024 * 1024;
    const base = 0x10000;
    const Memory = struct {
        bytes: [base + size]u8 = undefined,
        pool: gpu.parallel_copy.Pool = .{ .participants = .init(4) },
        fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address > self.bytes.len or destination.len > self.bytes.len - address) return false;
            self.pool.copy(destination, self.bytes[@intCast(address)..][0..destination.len]);
            return true;
        }
        fn write(context: ?*anyopaque, address: u64, source: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address > self.bytes.len or source.len > self.bytes.len - address) return false;
            self.pool.copy(self.bytes[@intCast(address)..][0..source.len], source);
            return true;
        }
    };
    const guest = try allocator.create(Memory);
    defer allocator.destroy(guest);
    guest.* = .{};
    defer guest.pool.deinit();
    @memset(&guest.bytes, 0);
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true, .defer_small_storage_writes = true });
    defer renderer.deinit();
    _ = renderer.dcbBackend(.{ .context = guest, .read = Memory.read, .write = Memory.write });
    const code = [_]u32{
        vop1(1, 0, 8), vop1(1, 1, 255), 0x1234_5678,
        0xe070_1000, 0x8000_0100, // write one dword inside the large V#s0
        0xbf81_0000,
    };
    for (code, 0..) |word, i| std.mem.writeInt(u32, guest.bytes[0x100 + i * 4 ..][0..4], word, .little);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 9 << 1);
    for ([_]u32{ base, 4 << 16, size / 4, 0 }, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
    for ([_]u8{ 4, 1, 2, 4 }, 0..) |participants, pass| {
        guest.pool.participants.store(participants, .release);
        const bytes = guest.bytes[base..];
        for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% (i >> 12) +% pass);
        const offset: u32 = @intCast(if (pass == 3) size - 4 else pass * size / 4);
        try state.writeRegister(.shader, compute.userDataBase() + 8, offset);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try renderer.flushPendingGuestWrites();
        try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, bytes[offset..][0..4], .little));
        for (bytes, 0..) |byte, i| {
            if (i >= offset and i < offset + 4) continue;
            try std.testing.expectEqual(@as(u8, @truncate(i *% 17 +% (i >> 12) +% pass)), byte);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), guest.pool.worker_count);
    std.debug.print("parallel copy passed: 16 MiB Vulkan uploads/readbacks, 1/2/4 participants, CPU updates and partial GPU writes\n", .{});
}

fn runLargeIndirectImageProbe(allocator: std.mem.Allocator) !void {
    const count = 4352;
    const groups = count + 1;
    var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
    defer renderer.deinit();
    if (!renderer.sampled_image_nonuniform_indexing or renderer.device_info.sampled_image_capacity < count)
        return error.LargeSampledImageTableUnavailable;
    const guest = try allocator.create(SizedGuestMemory(2 * 1024 * 1024));
    defer allocator.destroy(guest);
    guest.* = .{};
    _ = renderer.dcbBackend(guest.interface());
    const table = 0x10000;
    const output = 0x40000;
    const textures = 0x80000;
    const code = [_]u32{
        0x9314_a018, // s_mul_i32 s20, s24 (workgroup X), 32
        0xf42c_0004,    20 << 25, // s_buffer_load_dwordx8 s0, V#s8, s20
        vop1(1, 1, 24), vop1(1, 2, 255),
        0x3e80_0000,    vop1(1, 3, 255),
        0x3e80_0000,    0xf09c_010a,
        0x0080_0402,    3,
        0xe070_2000,    0x8003_0401,
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, (24 << 1) | (1 << 7));
    var userdata: [24]u32 = @splat(0);
    @memcpy(userdata[8..12], &[_]u32{ table, 32 << 16, count, 0 });
    @memcpy(userdata[12..16], &[_]u32{ output, 4 << 16, groups, 0 });
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    for (0..3) |relocation| {
        for (0..count) |index| {
            // A real material table contains 1320 copies of its fallback T#.
            // Keep a long run of exact aliases alongside distinct 2D/3D views.
            const texture = if (relocation == 0) index else if (relocation == 2 and index < 1320) count - 1 else count - index - 1;
            var image = sampledImageDescriptorWords(textures + @as(u32, @intCast(texture)) * 256, 1, 1);
            // A distinct view of the first allocation must still select blue,
            // even though its address word matches another candidate exactly.
            if (texture == count - 1) {
                image = sampledImageDescriptorWords(textures, 1, 1);
                image[3] = (image[3] & ~@as(u32, 7)) | 6;
            } else if (texture % 2 != 0) {
                image[3] = (image[3] & 0x0fff_ffff) | 0xa000_0000;
            }
            for (image, 0..) |word, component| guest.word(table + index * 32 + component * 4, word);
            guest.word(textures + texture * 256, 0xff80_0000 | @as(u32, @intCast(texture % 251 + 1)));
        }
        const result = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ groups, 1, 1 });
        try std.testing.expect(result.spirv_words != 0);
        var pixels: [groups * 4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(output, &pixels);
        for (0..groups) |index| {
            const texture = if (index == count) count else if (relocation == 0) index else if (relocation == 2 and index < 1320) count - 1 else count - index - 1;
            const expected: f32 = if (texture == count) 0 else if (texture == count - 1) 128.0 / 255.0 else @as(f32, @floatFromInt(texture % 251 + 1)) / 255.0;
            const actual: f32 = @bitCast(std.mem.readInt(u32, pixels[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
        try std.testing.expectEqual(@as(usize, 1), renderer.resident_samplers.items.len);
    }
    // Exercise the independent graphics resource/upload path as well. A flat
    // vertex export selects entry zero at runtime; after relocation this is
    // the blue view of the first allocation, not its ordinary red view.
    const vertex = [_]u32{
        vop1(6, 1, 261),
        vop1(1, 2, 255),
        0x3f80_0000,
        vop2(4, 3, 1, 2),
        vop1(1, 4, 255),
        0x3f40_0000,
        vop2(8, 5, 3, 4),
        vop2(8, 6, 3, 3),
        vop1(1, 7, 255),
        0xbfc0_0000,
        vop2(8, 6, 6, 7),
        vop1(1, 8, 255),
        0x3f40_0000,
        vop2(3, 6, 6, 8),
        vop1(1, 7, 128),
        vop1(1, 8, 242),
        0xf800_021f,
        0x0707_0707,
        0xf800_08cf,
        0x0807_0605,
        0xbf81_0000,
    };
    const fragment = [_]u32{
        0xc802_0002 | (18 << 18), // V_INTERP_MOV P0, ATTR0.x
        vop1(2, 20, 256 + 18), // V_READFIRSTLANE s20, v18
        0x9314_a014,
        0xf42c_0004,
        20 << 25,
        vop1(1, 2, 240),
        vop1(1, 3, 240),
        0xf080_0f0a, // implicit LOD remains valid across both view banks
        0x0080_0402,
        3,
        0xf800_080f,
        0x0706_0504,
        0xbf81_0000,
    };
    for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
    for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
    for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
        try state.writeRegister(.shader, stage.programRegisterBase(), address);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase() + 3, 24 << 1);
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase() + @as(u32, @intCast(index)), word);
    const context = [_][2]u32{
        .{ 0x318, 0x20 },            .{ 0x319, 7 }, .{ 0x31b, 0 },               .{ 0x31c, 10 << 2 },
        .{ 0x31d, 0 },               .{ 0x390, 0 }, .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },
        .{ 0x08e, 0xf },             .{ 0x00c, 0 }, .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },
        .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 }, .{ 0x200, 0 },               .{ 0x202, (0xcc << 16) | (1 << 4) },
        .{ 0x204, 0 },               .{ 0x205, 0 }, .{ 0x191, 0x401 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
    if (renderer.last_draw_error) |err| return err;
    try renderer.flushPendingGuestWrites();
    const center = 0x2000 + (32 * 64 + 32) * 4;
    std.debug.print("large sampled fragment center={any}\n", .{guest.bytes[center..][0..4].*});
    try std.testing.expectEqual(@as(u8, 128), guest.bytes[center]);
    std.debug.print("large indirect sampled images passed: compute/fragment lookup, 4352 mixed 2D/3D views, exact aliases, null bounds, relocated table and shared sampler\n", .{});
}

fn runQueuedDetileProbe(allocator: std.mem.Allocator) !void {
    const count = 70; // exceed the detile descriptor pool before readback
    const texture_stride = 512 * 1024;
    const textures = 0x100000;
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    const guest = try allocator.create(SizedGuestMemory(textures + count * texture_stride));
    defer allocator.destroy(guest);
    guest.* = .{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0x9314_a018, // s20 = workgroup X * 32
        0xf42c_0004,    20 << 25, // s[0:7] = table[s20]
        vop1(1, 1, 24), vop1(1, 2, 255),
        0x3e80_0000,    vop1(1, 3, 255),
        0x3e80_0000,    0xf09c_010a,
        0x0080_0402,    3,
        0xe070_2000,    0x8003_0401,
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, (24 << 1) | (1 << 7));
    var userdata: [24]u32 = @splat(0);
    @memcpy(userdata[8..12], &[_]u32{ 0x10000, 32 << 16, count, 0 });
    @memcpy(userdata[12..16], &[_]u32{ 0x20000, 4 << 16, count + 1, 0 });
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    for (0..3) |round| {
        // Cover the direct path, rebased mip views, and the diagnostic CPU path.
        renderer.direct_detile_uploads = round != 2;
        const base_level: u32 = if (round == 1) 1 else 0;
        for (0..count) |index| {
            const address: u32 = @intCast(textures + index * texture_stride);
            var image = sampledImageDescriptorWords(address, 256, 256);
            image[3] |= (base_level << 12) | (3 << 16) | (@as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20);
            image[5] = 3 << 4;
            for (image, 0..) |word, component| guest.word(0x10000 + index * 32 + component * 4, word);
            const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
            try std.testing.expect(texture.required_source_bytes <= texture_stride);
            for (0..4) |level| {
                const view = try texture.subresource(@intCast(level), 0, 1);
                const value: u32 = @intCast(1 + index + level * 40 + round * 7);
                for (0..view.height) |y| for (0..view.width) |x| {
                    const at = address + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                    guest.word(at, 0xff00_0000 | value);
                };
            }
        }
        const before = renderer.direct_detile_upload_count;
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ count + 1, 1, 1 });
        try std.testing.expectEqual(before + @as(u64, if (round == 2) 0 else count), renderer.direct_detile_upload_count);
        var pixels: [(count + 1) * 4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x20000, &pixels);
        for (0..count + 1) |index| {
            const expected: f32 = if (index == count) 0 else @as(f32, @floatFromInt(1 + index + base_level * 40 + round * 7)) / 255.0;
            const actual: f32 = @bitCast(std.mem.readInt(u32, pixels[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
    }
    std.debug.print("queued detile uploads passed: 70 distinct textures, descriptor reuse, four mip levels, rebased views, updates, OOB and CPU-path agreement\n", .{});
}

fn runIndirectImageProbe(allocator: std.mem.Allocator) !void {
    for (0..10) |case_index| {
        var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
        defer renderer.deinit();
        if (!renderer.sampled_image_nonuniform_indexing) return error.NonuniformSampledImagesUnavailable;
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const wrapping = case_index == 1;
        const guarded = case_index == 2 or case_index == 4 or case_index == 5;
        const compact = case_index >= 8;
        const wide = case_index == 3 or case_index == 9;
        const material_constants = case_index == 6;
        const mixed_views = case_index == 7;
        const offset_register: u32 = if (case_index == 4 or case_index == 5) 106 + @as(u32, @intCast(case_index - 4)) else 20;
        if (wide and renderer.device_info.sampled_image_capacity < 128) {
            std.debug.print("128-texture case unavailable: device capacity={d}\n", .{renderer.device_info.sampled_image_capacity});
            continue;
        }
        const stride: u32 = if (material_constants) 388 else if (guarded) 368 else if (wrapping) 48 else 32;
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
            if (mixed_views) vop1(1, 4, 255) else 0xbf80_0000,
            if (mixed_views) 0x3f40_0000 else 0xbf80_0000,
            if (mixed_views) 0xf09c_0112 else if (compact) 0xf09c_810a else 0xf09c_010a,
            if (mixed_views) 0x0080_0202 else if (compact) 0x0081_0402 else 0x0080_0402,
            if (mixed_views) 0x0403 else 3, // overlapping destination checks coordinate preservation across view banks
            0xe070_2000,
            if (mixed_views) 0x8003_0201 else 0x8003_0401,
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
        if (material_constants) {
            // The unbounded product visits every word-aligned table window.
            // Material floats can resemble 1D-array/cube T#s, but their
            // reserved dimension bit or channel selectors make them invalid.
            const constants = [_][8]u32{
                .{ 0x40a0_0000, 0x4120_0000, 0x4120_0000, 0xc110_0000, 0, 0, 0, 0x3f80_0000 },
                .{ 0x100, 56 << 20, 0, 0xb000_0fae, 0, 0, 0, 0 },
            };
            for (constants, 0..) |words, record| for (words, 0..) |word, component|
                guest.word(table + record * stride + 160 + component * 4, word);
        }
        const ordinary_addresses = [_]u32{ 0x8000, 0x9000, 0x8000 };
        // A linear guest row has 256-byte alignment. One texel per image
        // keeps the wide fixture's adjacent 256-byte allocations disjoint.
        const extent: u32 = if (wide) 1 else 4;
        for (0..if (wide) @as(usize, 128) else 3) |index| {
            const address = if (wide) 0x8000 + @as(u32, @intCast(index)) * 256 else ordinary_addresses[index];
            var image = sampledImageDescriptorWords(address, extent, extent);
            if (mixed_views and index == 1) {
                image[3] = (image[3] & 0x0fff_ffff) | 0xa000_0000;
                image[4] = 1; // two volume slices; v4 selects the second
            }
            if (!wide and index == 2) image[3] = (image[3] & ~@as(u32, 7)) | 6; // same allocation, blue in red channel
            if (compact) {
                // One coalesced eight-word load carries four unrelated words
                // followed by a compact T#. Adjacent s8:s11 hold the V# and
                // must not participate in the GPU's texture lookup key.
                for (image[0..4], 0..) |word, component| guest.word(table + index * stride + 16 + component * 4, word);
                guest.word(table + index * stride, 146);
            } else for (image, 0..) |word, component| guest.word(table + (if (wrapping) @as(usize, 16) else 0) + index * stride + component * 4, word);
            const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
            const surface = try layout.base();
            for (0..if (mixed_views and index == 1) @as(usize, 2) else 1) |z| for (0..extent) |y| for (0..extent) |x| {
                const pixel = address + @as(usize, @intCast(try surface.sourceByteOffset(@intCast(x), @intCast(y), @intCast(z), 0)));
                guest.word(pixel, if (mixed_views and index == 1 and z == 0) 0xff00_00aa else if (wide) 0xff00_0000 | @as(u32, @intCast(index + 1)) else if (index != 1) 0xff80_00ff else 0xff00_0040);
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
    try runMaskedPointerImageProbe(allocator);
    std.debug.print("indirect sampled images passed: runtime selection, aliases, bounds, wrapping, guarded SGPR/VCC offsets, 128 textures and mixed 2D/3D views\n", .{});
}

fn runMaskedPointerImageProbe(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |spill| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const store = mubuf(0x1c, 0, 4, 1, 12);
        const code = [_]u32{
            vop1(1, 1, 20), // preserve workgroup ID for output
            0x8f18_8214, // byte offset = workgroup * 4
            0xf420_0602,                             24 << 25, // scalar index from V#s4
            if (spill) 0xd761_0027 else 0xbf80_0000,
            if (spill) 24 | (136 << 9) else 0xbf80_0000, // save index in v39 lane8
            if (spill) 0xbe98_03ff else 0xbf80_0000,
            if (spill) 0xffff_ffff else 0xbf80_0000, // borrow s24
            if (spill) 0xd760_0018 else 0xbf80_0000,
            if (spill) 295 | (136 << 9) else 0xbf80_0000, // restore index
            0x9318_ff18, 816, // material record offset
            0xf42c_0404, (24 << 25) | 136, // shared sampler s16:s19 in a coalesced material load
            0xf424_0604, (24 << 25) | 556, // two material words, first holds texture selector
            0x876a_ff18, 255, // VCC_LO = selector & 255
            0x8f6a_856a, // byte offset = VCC_LO << 5
            0xf40c_0600,     (106 << 25) | 544, // full T#s24 from pointer SRT
            vop1(1, 2, 255), 0x3e80_0000,
            vop1(1, 3, 255), 0x3e80_0000,
            0xf09c_010a,     0x0086_0402,
            3,               store[0],
            store[1],        0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        for (0..2) |index| {
            const address: u32 = 0x8000 + @as(u32, @intCast(index)) * 0x1000;
            const image = sampledImageDescriptorWords(address, 1, 1);
            for (image, 0..) |word, component| guest.word(0x2000 + 544 + index * 32 + component * 4, word);
            guest.word(address, if (index == 0) 0xff00_00ff else 0xff00_0040);
        }
        // The root contains exactly two T#s. Later bytes are unrelated data,
        // so enumerating all 256 values of the mask must not be necessary.
        guest.word(0x2000 + 544 + 64, 0xdead_beef);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, 1);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, (20 << 1) | (1 << 7));
        var userdata: [20]u32 = @splat(0);
        userdata[0] = 0x2000;
        @memcpy(userdata[4..8], &[_]u32{ 0x3000, 4 << 16, 4, 0 });
        @memcpy(userdata[8..12], &[_]u32{ 0x4000, 816 << 16, 2, 0 });
        @memcpy(userdata[12..16], &[_]u32{ 0x10000, 4 << 16, 6, 0 });
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
        for (0..2) |round| {
            for ([_]u32{ 0, 1, 0, 1 }, 0..) |value, index| guest.word(0x3000 + index * 4, value);
            if (round != 0) guest.word(0x3000 + 12, 0);
            guest.word(0x4000 + 556, if (round == 0) 0x3f80_0000 else 0xabcd_ef01);
            guest.word(0x4000 + 816 + 556, if (round == 0) 0xabcd_ef01 else 0x3f80_0000);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 6, 1, 1 });
            var output: [24]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x10000, &output);
            for (0..6) |group| {
                const record: usize = if (group >= 4 or (round != 0 and group == 3)) 0 else group % 2;
                const expected: f32 = if (record == round) 1 else 64.0 / 255.0;
                const actual: f32 = @bitCast(std.mem.readInt(u32, output[group * 4 ..][0..4], .little));
                try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
            }
        }
        guest.word(0x4000 + 816 + 136, 0x400);
        try std.testing.expectError(error.UnsupportedSampledImage, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 6, 1, 1 }));
        std.debug.print("masked pointer images passed: spill={}, indexed materials, VCC mask, bounded SRT, OOB and refreshed indices\n", .{spill});
    }
}

fn runGraphicsDescriptorReuseProbe(allocator: std.mem.Allocator) !void {
    for (0..4) |case_index| {
        const array_first = case_index == 1;
        const query_lod = case_index >= 2;
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        const vertex = [_]u32{
            vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
            vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
            vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
            0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
            0xf800_08cf,     0x0807_0605,      0xbf81_0000,
        };
        const sample_fragment = [_]u32{
            0xf40c_0006,     125 << 25, // T#s0 from pointer s12:s13
            vop1(1, 0, 240), vop1(1, 1, 240),
            vop1(1, 2, 128), if (array_first) 0xf09c_0f28 else 0xf09c_0f08,
            0x0040_0400,
            0xf40c_0006, (125 << 25) | 32, // same SGPRs, different 2D image
            0xf11c_0408, 0x0040_0800, // gather blue into v8:v11
            0xf11c_0408,      0x0040_0c00, // same descriptor, another instruction
            vop1(1, 15, 242), 0xf800_080f,
            0x0f0c_0504,      0xbf81_0000,
        };
        // A query-only shader needs its own texture binding. UV gradients over
        // a 64-pixel target and a 4-texel image give unclamped LOD -4; dmask=2
        // packs that second query component into the first destination VGPR.
        const lod_fragment = [_]u32{
            0xf40c_0006,                                       125 << 25,
            0xc801_0000,                                       0xc805_0100,
            if (case_index == 2) 0xf180_0208 else 0xf180_0308, 0x0040_0400,
            vop1(1, 8, 255),                                   0xbe80_0000,
            vop2(8, 9, if (case_index == 2) 4 else 5, 8),      vop1(1, 10, 128),
            vop1(1, 15, 242),                                  0xf800_080f,
            if (case_index == 2) 0x0f0a_0a09 else 0x0f0a_0409, 0xbf81_0000,
        };
        const fragment: []const u32 = if (query_lod) &lod_fragment else &sample_fragment;
        for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
        for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
        const extent: u32 = if (query_lod) 4 else 1;
        var first = sampledImageDescriptorWords(0x10000, extent, extent);
        if (array_first) first[3] = (first[3] & 0x0fff_ffff) | (13 << 28);
        const second = sampledImageDescriptorWords(0x11000, 1, 1);
        for (first, 0..) |word, index| guest.word(0x18000 + index * 4, word);
        for (second, 0..) |word, index| guest.word(0x18020 + index * 4, word);
        guest.word(0x10000, 0xff00_00ff);
        guest.word(0x11000, 0xffff_0000);
        var state = gpu.State{};
        for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
            try state.writeRegister(.shader, stage.programRegisterBase(), address);
            try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        }
        const pixel = gpu.resources.ShaderStage.pixel;
        try state.writeRegister(.shader, pixel.userDataBase() - 1, 14 << 1);
        for ([_]u32{ 0, 0, 0, 0, 0x18000, 0 }, 0..) |word, index|
            try state.writeRegister(.shader, pixel.userDataBase() + 8 + @as(u32, @intCast(index)), word);
        const context = [_][2]u32{
            .{ 0x318, 0x20 },                    .{ 0x319, 7 },               .{ 0x31b, 0 },               .{ 0x31c, 10 << 2 }, .{ 0x31d, 0 },
            .{ 0x390, 0 },                       .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },         .{ 0x08e, 0xf },     .{ 0x00c, 0 },
            .{ 0x00d, 64 | (64 << 16) },         .{ 0x094, 1 << 31 },         .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 },       .{ 0x200, 0 },
            .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },               .{ 0x205, 0 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index|
            try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        if (renderer.last_draw_error) |err| return err;
        try renderer.flushPendingGuestWrites();
        const center = 0x2000 + (32 * 64 + 32) * 4;
        try std.testing.expectEqual(@as(u32, if (query_lod) 0xff00_00ff else 0xffff_00ff), std.mem.readInt(u32, guest.bytes[center..][0..4], .little));
        try std.testing.expectEqual(@as(u64, if (query_lod) 1 else 2), renderer.texture_cache_misses);
    }
    std.debug.print("graphics descriptor reuse passed: 2D/array sample followed by 2D gather, distinct images, repeated physical binding and query-only LOD masks\n", .{});
}

fn runUnsupportedTextureContinuationProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const program = [_]u32{
        vop1(1, 0, 240), vop1(1, 1, 240),
        0xf09c_0f08, 0x0040_0400, // sample T#s0, S#s8
        0xe078_0000, 0x8003_0400, // store v4:v7 through V#s12
        0xbf81_0000,
    };
    for (program, 0..) |word, index| guest.word(0x800 + index * 4, word);
    var descriptor = sampledImageDescriptorWords(0x10000, 1, 1);
    descriptor[3] |= 7 << 20; // unsupported guest tile mode
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try state.writeRegister(.shader, reg, 1);
    for (descriptor, 0..) |word, index|
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    for ([_]u32{ 0, 0, 0, 0, 0x11000, 4 << 16, 4, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, compute.userDataBase() + 8 + @as(u32, @intCast(index)), word);
    guest.word(0x11000, 0xdead_beef);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    const result = try executor.execute(&.{
        command(gpu.pm4.dispatch_direct, 4),          1,               1,       1,      0x41,
        customCommand(gpu.pm4.custom.release_mem, 7), 0x28 | (5 << 8), 2 << 29, 0x7000, 0,
        98,                                           0,               0,
    });
    try std.testing.expectEqual(gpu.executor.Status.complete, result.status);
    try std.testing.expectEqual(error.UnsupportedTileMode, renderer.last_dispatch_error.?);
    try std.testing.expectEqual(@as(u64, 98), std.mem.readInt(u64, guest.bytes[0x7000..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), std.mem.readInt(u32, guest.bytes[0x11000..][0..4], .little));
    // A skipped pass must leave the renderer usable for subsequent valid work.
    try runIndexedCopyKernel(allocator, &renderer, &guest, renderer.dcbBackend(guest.interface()));
    std.debug.print("unsupported texture continuation passed: release retained, output untouched, following compute verified\n", .{});
}

fn runWorkgroupImageTableProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const store = mubuf(0x1e, 0, 4, 2, 4);
    const program = [_]u32{
        vop1(1, 2, 3), // retain the original workgroup ID for the output
        0x9003_8103, // s3 >>= 1: two workgroups share each texture
        0x936b_ff03, 440, // VCC_HI = s3 * record stride
        0xf408_0500, 0xfa00_0000, // table V#s20 from pointer s0
        0xf42c_030a, 0xd600_0000, // T#s12 from table + VCC_HI
        0xf408_0100,      0xfa00_0010, // output V#s4 from pointer s0 + 16
        sop1(4, 24, 128), sop1(4, 26, 128),
        vop1(1, 0, 240),  vop1(1, 1, 240),
        0xf09c_0f08,      0x00c3_0400,
        store[0],         store[1],
        0xbf81_0000,
    };
    for (program, 0..) |word, index| guest.word(0x800 + index * 4, word);
    for ([_]u32{ 0x2000, 440 << 16, 2, 0, 0x11000, 16 << 16, 4, 0 }, 0..) |word, index|
        guest.word(0x1800 + index * 4, word);
    for (0..2) |record| {
        const image_words = sampledImageDescriptorWords(@intCast(0x10000 + record * 256), 1, 1);
        for (image_words, 0..) |word, index| guest.word(0x2000 + record * 440 + index * 4, word);
        // Ordinary record fields can look like a decodable descriptor. They
        // are unreachable for these group IDs and must never be staged.
        var poison = image_words;
        poison[3] |= 7 << 20;
        for (poison, 0..) |word, index| guest.word(0x2020 + record * 440 + index * 4, word);
        guest.word(0x10000 + record * 256, if (record == 0) 0xff00_00ff else 0xffff_0000);
    }
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, (3 << 1) | (1 << 7));
    for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try state.writeRegister(.shader, reg, 1);
    for ([_]u32{ 0x1800, 0, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    _ = try executor.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 4, 1, 1, 0x41 });
    if (renderer.last_dispatch_error) |err| return err;
    try std.testing.expectEqual(@as(u64, 1), renderer.translated_dispatches);
    var output: [64]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x11000, &output);
    for (0..4) |group| for (0..4) |channel| {
        const expected: u32 = if (channel == 3 or channel == (if (group < 2) @as(usize, 0) else 2)) 0x3f80_0000 else 0;
        if (expected != std.mem.readInt(u32, output[(group * 4 + channel) * 4 ..][0..4], .little))
            std.debug.print("workgroup table output group={d} channel={d} bytes={x}\n", .{ group, channel, output });
        try std.testing.expectEqual(expected, std.mem.readInt(u32, output[(group * 4 + channel) * 4 ..][0..4], .little));
    };
    try std.testing.expectEqual(@as(u64, 2), renderer.texture_cache_misses);
    std.debug.print("workgroup image table passed: shifted group IDs, 440-byte records, unreachable descriptor-like fields and per-group colors\n", .{});
}

fn runHighHalfStoreProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    for ([_]usize{ 1, 2 }, 0..) |width, case_index| {
        const program_address: u32 = @intCast(0x800 + case_index * 256);
        const code = [_]u32{
            0xe030_2000,                                  0x8000_0100, // load input[lane] into v1
            if (width == 1) 0xe064_2001 else 0xe06c_2001,
            0x8001_0100, // store v1 high byte/halfword at output[lane] + 1
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(program_address + index * 4, word);
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase(), program_address >> 8);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 8 << 1);
        try state.writeRegister(.shader, 0x207, 64);
        try state.writeRegister(.shader, 0x208, 1);
        try state.writeRegister(.shader, 0x209, 1);
        const descriptors = [_]u32{ 0x4000, 4 << 16, 64, 0, 0x5000, @as(u32, @intCast(width)) << 16, @intCast(256 / width), 0 };
        for (descriptors, 0..) |word, index|
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
        for (0..2) |pass| {
            @memset(guest.bytes[0x5000..0x5100], 0x5a);
            var expected: [256]u8 = @splat(0x5a);
            for (0..64) |lane| {
                const value = @as(u32, 0x89ab_cdef) +% (@as(u32, @intCast(lane + pass * 71)) *% 0x0103_070b);
                guest.word(0x4000 + lane * 4, value);
                for (0..width) |byte|
                    expected[1 + lane * width + byte] = @truncate(value >> @as(u5, @intCast(16 + byte * 8)));
            }
            const before = renderer.translated_dispatches;
            const cache_hits = renderer.pipeline_cache_hits;
            _ = try executor.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 });
            if (renderer.last_dispatch_error) |err| return err;
            try renderer.flushPendingGuestWrites();
            try std.testing.expectEqual(before + 1, renderer.translated_dispatches);
            if (pass != 0) try std.testing.expectEqual(cache_hits + 1, renderer.pipeline_cache_hits);
            try std.testing.expectEqualSlices(u8, &expected, guest.bytes[0x5000..0x5100]);
        }
    }
    std.debug.print("high-half stores passed: 64 adjacent lanes, unaligned byte/halfword writes, guards and changed inputs on cache hits\n", .{});
}

// Exercise the hardware values supplied to an indexed LS and consumed by its
// HS. Three-vertex patches cross wave boundaries; the final group has only
// nine vertices. Data lives above 16 KiB in LDS and must survive the barrier.
fn runIndexedTessellationProbe(allocator: std.mem.Allocator) !void {
    try runNativeLsHsProbe(allocator, true);
    try runNativeLsHsProbe(allocator, false);
}

fn runNativeLsHsProbe(allocator: std.mem.Allocator, triangles: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    const guest = try allocator.create(GuestMemory);
    defer allocator.destroy(guest);
    guest.* = .{};
    _ = renderer.dcbBackend(guest.interface());
    const local_code = [_]u32{
        sop2(0x1e, 96, 3, 144), // active LS lanes in s3[7:0]
        sop2(0x29, 126, 193, 96), // EXEC = low active bits of -1
        vop1(1, 4, if (triangles) 20 else 13), // high user SGPR, alongside v2/v3/v5
        vop2Source(0x1a, 10, 132, 0), // local ID * 16
        0xd800_0000 | (if (triangles) @as(u32, 0x4000) else 0) | (0xdf << 18),
        (2 << 8) | 10,
        0xbefd_2106, // hardware LS -> HS continuation
    };
    const hull_code = [_]u32{
        0xf408_0200, 0xfa00_0000, // s[8:11] = root-table output descriptor
        sop1(4, 126, 193), // restore EXEC before the stage's barrier
        0xbf8a_0000,
        sop2(0x1e, 96, 3, 144),
        sop2(0x29, 126, 193, 96),
        vop2Source(0x1b, 10, 255, 1), 255, // relative patch in v1[7:0]
        vop2Source(0x0b, 10, if (triangles) 131 else 132, 10), // patch * control points
        vop2Source(0x16, 11, 136, 1), // control point in v1[15:8]
        vop2(0x25, 10, 11, 10),
        vop2Source(0x1a, 10, 132, 10),
        0xd800_0000 | (if (triangles) @as(u32, 0x4000) else 0) | (0xff << 18),
        (20 << 24) | 10,
        sop2(0x20, 12, 2, 131), // group output = offchip offset / 8
        0xbf8c_3f70,
        0xe000_1000 | (0x1e << 18),
        (12 << 24) | (2 << 16) | (20 << 8) | 10,
        0xbf81_0000,
    };
    for (local_code, 0..) |word, i| guest.word(0x800 + i * 4, word);
    for (hull_code, 0..) |word, i| guest.word(0x1000 + i * 4, word);
    const reader = gpu.ShaderMemoryReader{ .context = guest, .read_fn = GuestMemory.read };
    var local = try gpu.shader_analysis.decodeBounded(allocator, reader, 0x800, local_code.len, local_code.len * 4);
    defer local.deinit(allocator);
    var hull = try gpu.shader_analysis.decodeBounded(allocator, reader, 0x1000, hull_code.len, hull_code.len * 4);
    defer hull.deinit(allocator);
    for ([_]gpu.tessellation.Config.IndexFormat{ .uint16, .uint32 }) |format| {
        if (!triangles and format == .uint32) continue;
        var state = gpu.State{};
        try state.writeRegister(.uconfig, 0x242, 9);
        try state.writeRegister(.context, 0x2d6, if (triangles) 0xc355 else 0x1043f);
        try state.writeRegister(.context, 0x2db, if (triangles) 0x40049 else 0x4006a);
        try state.writeRegister(.shader, 0x10b, 40 << 18);
        try state.writeRegister(.shader, 0x148, 8);
        try state.writeRegister(.shader, 0x102, 0x2000);
        try state.writeRegister(.shader, 0x103, 0);
        for (0..6) |i| try state.writeRegister(.shader, @intCast(0x10c + i), 0);
        try state.writeRegister(.shader, 0x111, 0xdead_beef);
        try state.writeRegister(.shader, 0x118, 0xdead_beef);
        var config = (try gpu.tessellation.Config.decode(&state)).?;
        config.index_format = if (triangles) format else null;
        var entry = try gpu.tessellation.Entry.init(allocator, config, &local, &hull);
        defer entry.deinit(allocator);
        for (entry.merged.code.items, 0..) |word, i| guest.word(0x10000 + i * 4, word);
        for ([_]u32{ 0x4000, 0, 8192, 0xfac }, 0..) |word, i| guest.word(0x2000 + i * 4, word);
        @memset(guest.bytes[0x4000..0x6000], 0xcd);
        const index_bytes: usize = if (format == .uint16) 2 else 4;
        for (0..264) |i| {
            const index: u32 = @intCast(31 + (i * 73) % 264 + (if (format == .uint32) @as(usize, 100000) else 0));
            if (format == .uint16)
                std.mem.writeInt(u16, guest.bytes[0x3000 + i * index_bytes ..][0..2], @intCast(index), .little)
            else
                guest.word(0x3000 + i * index_bytes, index);
        }
        if (triangles)
            try config.prepareIndexedState(&state, 11, 88, -7, 0x3000)
        else
            try config.prepareState(&state, 11, 66);
        try state.writeRegister(.shader, 0x20c, 0x100);
        _ = try renderer.dispatchRdna2State(&state, .{ config.localSize(), 1, 1 }, .{ 2, 1, 1 });
        var output: [8192]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x4000, &output);
        for (0..2) |group| for (0..256) |lane| {
            const vertices: usize = if (triangles) 255 else 252;
            const i = group * vertices + lane;
            const active = lane < vertices and i < 264;
            const index: u32 = @intCast(if (triangles) 24 + (i * 73) % 264 + (if (format == .uint32) @as(usize, 100000) else 0) else lane % 4);
            const instance: u32 = @intCast(if (triangles) 11 else 11 + i / 4);
            const expected: [4]u32 = if (active) .{ index, @intCast(lane), 0xdead_beef, instance } else @splat(0xcdcd_cdcd);
            for (expected, 0..) |value, channel| {
                const actual = std.mem.readInt(u32, output[(group * 256 + lane) * 16 + channel * 4 ..][0..4], .little);
                if (value != actual) std.debug.print("native LS/HS triangles={any} {s}: group={d} lane={d} channel={d}\n", .{ triangles, @tagName(format), group, lane, channel });
                try std.testing.expectEqual(value, actual);
            }
        };
    }
    std.debug.print("native LS/HS triangles={any} passed: indices/control points, base vertex, instance, high user SGPR, wave boundaries, LDS and partial group\n", .{triangles});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--indexed-tessellation")) {
        try runIndexedTessellationProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fragment-first-active")) {
        try runFragmentFirstActiveLaneProbe(allocator, false);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fragment-mask-first-lane")) {
        try runFragmentFirstActiveLaneProbe(allocator, true);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--deferred-shader-metadata")) {
        try runDeferredShaderMetadataProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--tessellation-inputs")) {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        try renderer.probeTessellationInputs();
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--high-half-stores")) {
        try runHighHalfStoreProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dispatcher-budget")) {
        try runDispatcherBudgetProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--spilled-lds")) {
        try runSpilledLdsProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--workgroup-image-table")) {
        try runWorkgroupImageTableProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--unsupported-texture-continuation")) {
        try runUnsupportedTextureContinuationProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--graphics-descriptor-reuse")) {
        try runGraphicsDescriptorReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--vector-carry")) {
        try runVectorCarryProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--wide-masks")) {
        try runWideMaskProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--indexed-images")) {
        try runIndexedImageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--shifted-images")) {
        try runShiftedImageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--inactive-image-tables")) {
        try runInactiveImageTableProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--integer-format-stores")) {
        try runIntegerFormatStoreProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--save-exec")) {
        try runSaveExecProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--wave32-masks")) {
        try runWave32MaskProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--selected-indices")) {
        try runTypedIndexSelectionProbe(allocator, true);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--counted-image-loop")) {
        try runCountedImageLoopProbe(allocator, .counted);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--uniform-image-loop")) {
        try runCountedImageLoopProbe(allocator, .uniform_limit);
        try runCountedImageLoopProbe(allocator, .masked_pointer);
        try runCountedImageLoopProbe(allocator, .masked_buffer);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--large-indirect-images")) {
        try runLargeIndirectImageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-content-cache")) {
        try runBufferContentCacheProbe(allocator, 0);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--draw-upload-rollover")) {
        for ([_]bool{ false, true }) |persistent| {
            var renderer = try vulkan.Renderer.init(allocator, .{ .persistent_host_mappings = persistent, .enable_timeline_scheduler = true });
            defer renderer.deinit();
            try renderer.probeDrawUploadRollover();
            std.debug.print("draw upload rollover passed: new/rebound inputs and queued spill retirement, persistent={}\n", .{persistent});
        }
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-view-coherence")) {
        try runBufferViewCoherenceProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--zero-depth-samples")) {
        try runZeroDepthSampleProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--depth-storage")) {
        try runDepthStorageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--reset-depth-extent")) {
        try runResetDepthExtentProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--host-readback")) {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        const elapsed = try renderer.probeHostReadback();
        std.debug.print("host readback passed: four 64 MiB reads of GPU-written data verified, CPU reads={d} us\n", .{elapsed / 1000});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--storage-read-placement")) {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        const elapsed = try renderer.probeStorageReadPlacement();
        std.debug.print("storage read placement passed: 16 dispatches per placement, 1 GiB input reads; host_cached={d}us device_local={d}us; changed-input sums verified\n", .{ elapsed[0] / 1000, elapsed[1] / 1000 });
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--device-storage")) {
        for ([_]bool{ false, true }) |use_waits| try runQueuedBufferReuseProbe(allocator, use_waits, false, 64 * 1024 * 1024);
        try runBufferContentCacheProbe(allocator, 64 * 1024 * 1024);
        try runDeviceStorageBudgetProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--persistent-mapping")) {
        for ([_]bool{ false, true, false, true }) |persistent| {
            var renderer = try vulkan.Renderer.init(allocator, .{ .persistent_host_mappings = persistent, .enable_timeline_scheduler = true });
            defer renderer.deinit();
            const elapsed = try renderer.probeBufferMappings();
            std.debug.print("buffer mapping passed: persistent={any} 512 subrange writes={d} us, GPU copy and readback verified\n", .{ persistent, elapsed / 1000 });
        }
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--depth-pass-cache")) {
        for ([_]bool{ false, true }) |persistent| {
            var renderer = try vulkan.Renderer.init(allocator, .{ .persistent_depth_passes = persistent, .enable_timeline_scheduler = true });
            defer renderer.deinit();
            try renderer.probeDepthPassCache();
            std.debug.print("depth pass cache passed: persistent={any}, indexed depth/stencil, empty draw and smaller render area\n", .{persistent});
        }
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--feedback-snapshot")) {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
        defer renderer.deinit();
        try renderer.probeFeedbackSnapshots();
        std.debug.print("feedback snapshots passed: queued GPU source changes, sRGB views, distinct preserved copies, retirement and no guest readback\n", .{});
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--distinct-scalar-loads")) {
        try runDistinctScalarLoadProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--paired-lds64")) {
        try runPairedLds64Probe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dcc-metadata-clear")) {
        try runDccMetadataClearProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--lds-wave-memory")) {
        try runLdsWaveMemoryProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--sampled-storage-refresh")) {
        try runSampledStorageRefreshProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--image-exec")) {
        try runPredicatedImageLoadProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--spilled-image-descriptor")) {
        for ([_]bool{ false, true }) |empty_index| {
            try runSpilledImageDescriptorProbe(allocator, false, empty_index);
            try runSpilledImageDescriptorProbe(allocator, true, empty_index);
        }
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--trigonometry")) {
        try runTrigonometricProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--quad-mode")) {
        try runWholeQuadModeProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--indirect-dispatch")) {
        try runIndirectDispatchProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--gather-lod")) {
        try runGatherLodProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--cube-arrays")) {
        try runCubeArrayProbe(allocator);
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--wave64-ballots")) {
        try runWave64BallotsProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--multi-wave64")) {
        try runMultiWave64Probe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dpp")) {
        try runDppProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-compaction")) {
        try runBufferCompactionProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-atomics")) {
        try runBufferAtomicProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scene-masks")) {
        try runSceneMaskProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--packed-floats")) {
        try runPackedFloatProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--deferred-release")) {
        try runDeferredReleaseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--image-resinfo")) {
        try runImageResinfoProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--image-d16")) {
        try runImageD16Probe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--sdwa")) {
        try runSdwaProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--storage-reuse")) {
        try runStorageImageReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--host-import")) {
        try runHostImportProbe(allocator, false);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--host-import-retain")) {
        try runHostImportProbe(allocator, true);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--sampled-dcc-clears")) {
        try runSampledDccClearProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--sampled-view-reuse")) {
        try runSampledViewReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--sampled-cache-budget")) {
        try runSampledCacheBudgetProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--sampled-scratch")) {
        try runSampledScratchProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--image-scratch")) {
        try runImageScratchProbe(allocator);
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--barycentric")) {
        try runBarycentricProbe(allocator);
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--queued-detile")) {
        try runQueuedDetileProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--typed-indices")) {
        try runTypedIndexProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--vector-buffer-addresses")) {
        try runVectorBufferAddressProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scalar-pointers")) {
        try runScalarPointerProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--flat-pointers")) {
        try runFlatPointerProbe(allocator);
        try runFlatWaveSnapshotProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--clean-buffer-retention")) {
        try runCleanBufferRetentionProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-cache-budget")) {
        try runBufferCacheBudgetProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scratch-memory")) {
        try runScratchMemoryProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--unbound-snapshots")) {
        try runUnboundSnapshotProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--bvh-intersections")) {
        try runBvhIntersectionProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--flat-apertures")) {
        try runFlatApertureProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scene-flat-pointers")) {
        try runSceneFlatPointerProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scene-bitset-pointers")) {
        try runSceneBitsetPointerProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fragment-shadow-pointers")) {
        try runFragmentShadowPointerProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--shadow-record-pointers")) {
        try runShadowRecordPointerProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--packed-half-clears")) {
        try runPackedHalfClearProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dcc-single-clears")) {
        try runDccSingleClearProbe(allocator);
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-tables")) {
        try runBufferTableProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--pipeline-cache")) {
        try runPipelineCacheProbe(allocator);
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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--stencil-only-ui")) {
        try runStencilOnlyUiProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scanout-channels")) {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        try renderer.probeScanoutChannelOrder();
        std.debug.print("VideoOut BGRA scanout preserves guest bytes and displays RGBA colours\n", .{});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fragment-coverage")) {
        try runFragmentCoverageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--ui-attachments")) {
        try runUiAttachmentProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fullscreen-orientation")) {
        try runFullscreenOrientationProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--guest-culling")) {
        try runGuestCullingProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fragment-face")) {
        try runFragmentFaceProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--fragment-position")) {
        try runFragmentPositionProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-target-coherence")) {
        try runBufferTargetCoherenceProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--target-reuse")) {
        try runResidentTargetReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-reuse")) {
        for ([_]bool{ false, true }) |use_waits| try runQueuedBufferReuseProbe(allocator, use_waits, false, 0);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--parallel-copy")) {
        try runParallelCopyProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--inline-metadata")) {
        try runInlineMetadataBufferProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--gds")) {
        try runGdsAtomicProbe(allocator);
        try runGdsWave64AppendProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--gds-memory")) {
        try runGdsMemoryProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--gds-resident")) {
        try runGdsResidentProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--packed-buffer")) {
        try runPackedBufferProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--packed-channel-order")) {
        try runPackedChannelOrderProbe(allocator);
        return;
    }
    if (args.len == 1) {
        try runDepthStorageProbe(allocator);
        try runNormalizedColorProbe(allocator);
        try runPackedFloatProbe(allocator);
        try runSdwaProbe(allocator);
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

    try runFragmentScalarReuseProbe(allocator, &renderer, &guest, backend, &state, color_target_address);
    try runFragmentStorageProbe(allocator, &renderer, &guest, backend, &state, color_target_address);
    try runIndexedCopyKernel(allocator, &renderer, &guest, backend);
    try runStorageImageCopyKernel(allocator, &renderer, &guest, backend);

    try runQueuedBufferReuseProbe(allocator, true, false, 0);

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
