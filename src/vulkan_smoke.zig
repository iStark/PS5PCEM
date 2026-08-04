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
    guest.word(program_address, (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255); // v_mov_b32 v0, literal
    guest.word(program_address + 4, 0x3f80_0000);
    guest.word(program_address + 8, (@as(u32, 3) << 25) | (@as(u32, 1) << 17) | 256); // v_add_f32 v1, v0, v0
    guest.word(program_address + 12, 0xbf81_0000); // s_endpgm

    const storage_address = 0x1000;
    const storage = guest.bytes[storage_address .. storage_address + 64];
    for (storage, 0..) |*byte, index| byte.* = @truncate(index * 3 + 1);
    const first_stage = try renderer.stageGuestStorageBuffer(storage_address, storage.len);
    const second_stage = try renderer.stageGuestStorageBuffer(storage_address, storage.len);
    if (first_stage.allocation_cache_hit or !second_stage.allocation_cache_hit) return error.InvalidBufferCacheResult;

    var state = gpu.State{};
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase(), program_address >> 8);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x207, 8);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    const stream = [_]u32{
        command(gpu.pm4.dispatch_direct, 4),
        2,
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

    var staged_readback: [64]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(storage_address, &staged_readback);
    if (!std.mem.eql(u8, storage, &staged_readback)) return error.StagedBufferMismatch;

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
