// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! hle — high-level emulation of the guest firmware.
//!
//! Guest binaries do not carry the firmware they call into; they import it by
//! numeric identifier and expect the runtime to supply implementations. This
//! module provides that machinery — identifier derivation, the symbol registry
//! the dynamic linker resolves against, the calling-convention boundary — and
//! the firmware libraries built on top of it.

pub const nid = @import("nid.zig");
pub const abi = @import("abi.zig");
pub const trace = @import("trace.zig");
pub const unwind = @import("unwind.zig");
pub const modules = @import("modules.zig");
pub const filesystem = @import("filesystem.zig");
pub const savedata = @import("savedata.zig");
pub const host_stack = @import("host_stack.zig");
pub const video_out = @import("video_out.zig");
pub const graphics_device = @import("graphics_device.zig");
pub const apr = @import("apr.zig");
pub const errno = @import("errno.zig");
pub const symbols = @import("symbols.zig");

pub const libs = struct {
    pub const audio = @import("libs/audio.zig");
    pub const bootstrap_services = @import("libs/bootstrap_services.zig");
    pub const cxx_abi = @import("libs/cxx_abi.zig");
    pub const dialogs = @import("libs/dialogs.zig");
    pub const fiber = @import("libs/fiber.zig");
    pub const kernel_event_queue = @import("libs/kernel_event_queue.zig");
    pub const kernel_info = @import("libs/kernel_info.zig");
    pub const kernel_ioctl = @import("libs/kernel_ioctl.zig");
    pub const agc = @import("libs/agc.zig");
    pub const agc_submit = @import("libs/agc_submit.zig");
    pub const kernel_aio = @import("libs/kernel_aio.zig");
    pub const kernel_files = @import("libs/kernel_files.zig");
    pub const kernel_memory = @import("libs/kernel_memory.zig");
    pub const kernel_runtime = @import("libs/kernel_runtime.zig");
    pub const kernel_sync = @import("libs/kernel_sync.zig");
    pub const kernel_threading = @import("libs/kernel_threading.zig");
    pub const libc_internal = @import("libs/libc_internal.zig");
    pub const network = @import("libs/network.zig");
    pub const platform_services = @import("libs/platform_services.zig");
    pub const png_dec = @import("libs/png_dec.zig");
    pub const playgo = @import("libs/playgo.zig");
    pub const psml = @import("libs/psml.zig");
    pub const registry = @import("libs/registry.zig");
    pub const services = @import("libs/services.zig");
    pub const pad = @import("libs/pad.zig");
    pub const sysmodule = @import("libs/sysmodule.zig");
    pub const system_service = @import("libs/system_service.zig");
    pub const ult = @import("libs/ult.zig");
    pub const user_service = @import("libs/user_service.zig");
    pub const videodec2 = @import("libs/videodec2.zig");
};

pub const Database = symbols.Database;
pub const Export = symbols.Export;
pub const Library = symbols.Library;
pub const Module = symbols.Module;
pub const SymbolType = symbols.SymbolType;
pub const KernelError = errno.KernelError;

/// Every firmware library the runtime provides.
///
/// Registration is explicit rather than automatic: the list is what the guest
/// can see, so it should be readable in one place.
pub fn registerAll(db: *Database, gpa: @import("std").mem.Allocator) symbols.Error!void {
    try libs.audio.register(db, gpa);
    try libs.agc.register(db, gpa);
    try libs.kernel_aio.register(db, gpa);
    try libs.bootstrap_services.register(db, gpa);
    try libs.cxx_abi.register(db, gpa);
    try libs.dialogs.register(db, gpa);
    try libs.fiber.register(db, gpa);
    try libs.kernel_event_queue.register(db, gpa);
    try libs.kernel_files.register(db, gpa);
    try libs.kernel_info.register(db, gpa);
    try libs.kernel_ioctl.register(db, gpa);
    try libs.kernel_memory.register(db, gpa);
    try libs.kernel_runtime.register(db, gpa);
    try libs.kernel_sync.register(db, gpa);
    try libs.kernel_threading.register(db, gpa);
    try libs.libc_internal.register(db, gpa);
    try libs.network.register(db, gpa);
    try libs.platform_services.register(db, gpa);
    try libs.png_dec.register(db, gpa);
    try libs.registry.register(db, gpa);
    try libs.services.register(db, gpa);
    try libs.pad.register(db, gpa);
    try libs.sysmodule.register(db, gpa);
    try libs.system_service.register(db, gpa);
    try libs.ult.register(db, gpa);
    try libs.user_service.register(db, gpa);
}

test {
    _ = libs.audio;
    _ = @import("audio_fs.zig");
    _ = libs.bootstrap_services;
    _ = libs.cxx_abi;
    _ = libs.dialogs;
    _ = libs.fiber;
    _ = nid;
    _ = abi;
    _ = trace;
    _ = unwind;
    _ = modules;
    _ = filesystem;
    _ = savedata;
    _ = host_stack;
    _ = video_out;
    _ = graphics_device;
    _ = apr;
    _ = errno;
    _ = symbols;
    _ = libs.kernel_event_queue;
    _ = libs.kernel_info;
    _ = libs.kernel_ioctl;
    _ = libs.png_dec;
    _ = libs.psml;
    _ = libs.agc;
    _ = libs.agc_submit;
    _ = libs.kernel_aio;
    _ = libs.kernel_files;
    _ = libs.kernel_memory;
    _ = libs.kernel_runtime;
    _ = libs.kernel_sync;
    _ = libs.kernel_threading;
    _ = libs.libc_internal;
    _ = libs.network;
    _ = libs.platform_services;
    _ = libs.registry;
    _ = libs.services;
    _ = libs.pad;
    _ = libs.sysmodule;
    _ = libs.system_service;
    _ = libs.ult;
    _ = libs.user_service;
}

// ---------------------------------------------------------------------------
// Registration tests
//
// A library's own test registers that library alone, so it cannot see an
// identifier two libraries both claim. These go through `registerAll` and call
// what the registry actually hands the dynamic linker, which is the only place
// a shadowed binding shows up.

/// Resolves one libSceAgc identifier exactly as `resolveHleExact` does.
fn agcEntryPoint(
    db: *const Database,
    comptime id: *const [nid.encoded_len:0]u8,
    comptime Signature: type,
) !*const Signature {
    const key = symbols.Key{
        .id = id[0..nid.encoded_len].*,
        .library = .{ .name = "libSceAgc", .version = 1 },
        .module = .{ .name = "libSceAgc" },
        .type = .function,
    };
    const symbol = db.find(key) orelse return error.IdentifierNotRegistered;
    return @ptrFromInt(symbol.address);
}

test "register-indirect count patches reach the handler that edits the packet" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const Patch = fn (u64, u32) callconv(abi.guest) i32;
    const cases = .{
        .{ "nCUgItdN2ms", gpu.pm4.set_sh_reg_indirect },
        .{ "whb1RL7K4Ss", gpu.pm4.set_context_reg_indirect },
        .{ "fRG-JOH5+sI", gpu.pm4.set_uconfig_reg_indirect },
    };

    inline for (cases) |case| {
        const patch = try agcEntryPoint(&db, case[0], Patch);
        const header = (@as(u32, 3) << 30) | (@as(u32, 3) << 16) |
            (@as(u32, case[1]) << 8);
        // The five words sceAgcDcbSet*RegistersIndirect emits. The count word
        // carries a seeded upper half so the patch has something to preserve.
        var packet = [_]u32{ header, 0x1000_2000, 0x0000_0004, 0x8000_0000, 0xfffc_0003 };

        try testing.expectEqual(errno.ok, patch(@intFromPtr(&packet), 9));
        try testing.expectEqual(@as(u32, 0xfffc_0009), packet[4]);
        try testing.expectEqual(header, packet[0]);
        try testing.expectEqual(@as(u32, 0x1000_2000), packet[1]);
        try testing.expectEqual(@as(u32, 0x0000_0004), packet[2]);
        try testing.expectEqual(@as(u32, 0x8000_0000), packet[3]);

        // A packet of another register space must be refused. The placeholder
        // this identifier used to resolve to accepted every address.
        packet[0] = (@as(u32, 3) << 30) | (@as(u32, 3) << 16) |
            (@as(u32, gpu.pm4.nop) << 8);
        try testing.expect(patch(@intFromPtr(&packet), 1) != errno.ok);
        try testing.expectEqual(@as(u32, 0xfffc_0009), packet[4]);
    }
}

test "DMA_DATA address patches reach the handler that edits the packet" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const Patch = fn (u64, u64) callconv(abi.guest) i32;
    const patch_destination = try agcEntryPoint(&db, "IxYiarKlXxM", Patch);
    const patch_source = try agcEntryPoint(&db, "cdDRpqcFGbU", Patch);

    // The seven words sceAgcDcbDmaData emits: control, source, destination,
    // then the byte count and its flags.
    const header = (@as(u32, 3) << 30) | (@as(u32, 5) << 16) |
        (@as(u32, gpu.pm4.dma_data) << 8);
    var packet = [_]u32{
        header,
        0x2400_0001,
        0x1111_1111,
        0x2222_2222,
        0x3333_3333,
        0x4444_4444,
        0x0500_0100,
    };

    try testing.expectEqual(errno.ok, patch_destination(@intFromPtr(&packet), 0x1234_5678_9abc_def0));
    try testing.expectEqual(@as(u32, 0x9abc_def0), packet[4]);
    try testing.expectEqual(@as(u32, 0x1234_5678), packet[5]);
    try testing.expectEqual(header, packet[0]);
    try testing.expectEqual(@as(u32, 0x2400_0001), packet[1]);
    try testing.expectEqual(@as(u32, 0x1111_1111), packet[2]);
    try testing.expectEqual(@as(u32, 0x2222_2222), packet[3]);
    try testing.expectEqual(@as(u32, 0x0500_0100), packet[6]);

    try testing.expectEqual(errno.ok, patch_source(@intFromPtr(&packet), 0xfedc_ba98_7654_3210));
    try testing.expectEqual(@as(u32, 0x7654_3210), packet[2]);
    try testing.expectEqual(@as(u32, 0xfedc_ba98), packet[3]);
    // The destination the previous call wrote is not disturbed.
    try testing.expectEqual(@as(u32, 0x9abc_def0), packet[4]);
    try testing.expectEqual(@as(u32, 0x1234_5678), packet[5]);
    try testing.expectEqual(header, packet[0]);
    try testing.expectEqual(@as(u32, 0x2400_0001), packet[1]);
    try testing.expectEqual(@as(u32, 0x0500_0100), packet[6]);

    // Neither patch may edit a packet of another kind.
    packet[0] = (@as(u32, 3) << 30) | (@as(u32, 5) << 16) |
        (@as(u32, gpu.pm4.nop) << 8);
    try testing.expect(patch_destination(@intFromPtr(&packet), 0) != errno.ok);
    try testing.expect(patch_source(@intFromPtr(&packet), 0) != errno.ok);
    try testing.expectEqual(@as(u32, 0x9abc_def0), packet[4]);
    try testing.expectEqual(@as(u32, 0x7654_3210), packet[2]);
}

test "draw index auto reports the size it writes" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const GetSize = fn () callconv(abi.guest) u32;
    const Draw = fn (?*libs.agc.CommandBuffer, u32, u64) callconv(abi.guest) ?[*]u32;
    const get_size = try agcEntryPoint(&db, "WrdP9Zxx3lQ", GetSize);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", Draw);

    try testing.expectEqual(@as(u32, 12), get_size());

    var words: [8]u32 = @splat(0xdead_beef);
    var buffer = libs.agc.CommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };

    try testing.expect(draw(&buffer, 3, 0) != null);
    const written = @intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr);
    try testing.expectEqual(@as(usize, get_size()), written);
    try testing.expectEqual(gpu.pm4.draw_index_auto, @as(u8, @truncate(words[0] >> 8)));
}
