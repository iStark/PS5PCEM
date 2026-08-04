// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runs the host-only Vulkan compute/staging/readback probe.

const std = @import("std");
const vulkan = @import("vulkan");
const gpu = @import("gpu");

const GuestMemory = struct {
    bytes: [8192]u8 = @splat(0),

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const report = try renderer.smokeTest();

    const program_address = 0x100;
    guest.word(program_address, 0xe030_0000); // buffer_load_dword v0, v0, s0:s3, 0
    guest.word(program_address + 4, 0x8000_0000);
    guest.word(program_address + 8, 0xe070_0000); // buffer_store_dword v0, v0, s4:s7, 0
    guest.word(program_address + 12, 0x8001_0000);
    guest.word(program_address + 16, 0xbf81_0000); // s_endpgm

    const first_storage_address = 0x1000;
    const second_storage_address = 0x1100;
    const storage_size = 64;
    @memset(guest.bytes[first_storage_address .. first_storage_address + storage_size], 0);
    @memset(guest.bytes[second_storage_address .. second_storage_address + storage_size], 0);
    guest.word(first_storage_address, 0xdead_beef);

    var state = gpu.State{};
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase(), program_address >> 8);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    try state.writeRegister(.shader, 0x207, 1);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    const descriptors = [_][4]u32{
        .{ @intCast(first_storage_address), 0, storage_size, 0 },
        .{ @intCast(second_storage_address), 0, storage_size, 0 },
    };
    for (descriptors, 0..) |descriptor, descriptor_index| {
        for (descriptor, 0..) |word, word_index| {
            try state.writeRegister(
                .shader,
                gpu.resources.ShaderStage.compute.userDataBase() + @as(u32, @intCast(descriptor_index * 4 + word_index)),
                word,
            );
        }
    }
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

    if (std.mem.readInt(u32, guest.bytes[first_storage_address..][0..4], .little) != 0xdead_beef or
        std.mem.readInt(u32, guest.bytes[second_storage_address..][0..4], .little) != 0xdead_beef)
    {
        return error.TranslatedStorageWriteMismatch;
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

    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print(
        "Vulkan {d}.{d}.{d}: {s}\n" ++
            "device API {d}.{d}.{d}, queue family {d}, validation {s}\n" ++
            "headless smoke passed: {d} compute dispatch, {d} staging bytes copied and verified\n" ++
            "translated RDNA2 passed: {d} dispatches, pipelines {d}/{d} miss/hit, buffers {d}/{d} miss/hit\n",
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
        },
    );
    try writer.flush();
}
