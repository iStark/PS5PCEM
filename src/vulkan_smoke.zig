// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runs the host-only Vulkan compute/staging/readback probe.

const std = @import("std");
const vulkan = @import("vulkan");
const gpu = @import("gpu");

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_graphics_probe = true });
    defer renderer.deinit();
    const args = try init.minimal.args.toSlice(allocator);
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
        std.debug.print(
            "images passed: storage load/NSA store writeback and compute image_sample_lz NSA\n",
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
    guest.word(vertex_pc, vop1(0x06, 1, 256)); // v_cvt_f32_u32 v1, v0 (VertexIndex)
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
    try state.writeRegister(.context, 0x202, 0xcc << 16);
    try state.writeRegister(.context, 0x204, 0);
    try state.writeRegister(.context, 0x205, 0);
    _ = try executor.execute(&draw_stream);
    _ = try executor.execute(&draw_stream);
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
    if (renderer.guest_graphics_draws != 3 or renderer.translated_draws != 4 or
        renderer.graphics_pipeline_cache_misses != 3 or renderer.guest_color_target_writes != 3 or
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

    try runIndexedCopyKernel(allocator, &renderer, &guest, backend);
    try runStorageImageCopyKernel(allocator, &renderer, &guest, backend);

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
