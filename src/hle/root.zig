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

/// Resolves one firmware identifier exactly as `resolveHleExact` does.
fn firmwareEntryPoint(
    db: *const Database,
    comptime library_name: []const u8,
    comptime id: *const [nid.encoded_len:0]u8,
    comptime Signature: type,
) !*const Signature {
    const key = symbols.Key{
        .id = id[0..nid.encoded_len].*,
        .library = .{ .name = library_name, .version = 1 },
        .module = .{ .name = library_name },
        .type = .function,
    };
    const symbol = db.find(key) orelse return error.IdentifierNotRegistered;
    return @ptrFromInt(symbol.address);
}

fn agcEntryPoint(
    db: *const Database,
    comptime id: *const [nid.encoded_len:0]u8,
    comptime Signature: type,
) !*const Signature {
    return firmwareEntryPoint(db, "libSceAgc", id, Signature);
}

fn agcDriverEntryPoint(
    db: *const Database,
    comptime id: *const [nid.encoded_len:0]u8,
    comptime Signature: type,
) !*const Signature {
    return firmwareEntryPoint(db, "libSceAgcDriver", id, Signature);
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

// ---------------------------------------------------------------------------
// sceAgcDriverSubmitMultiCommandBuffers

/// The signature the driver calls this entry point with: its queue context,
/// the buffer and size arrays, and how many of each.
const SubmitMultiCommandBuffers = fn (
    ?*const anyopaque,
    ?[*]const ?[*]const u32,
    ?[*]const u32,
    u32,
) callconv(abi.guest) i32;

/// Records what reached the renderer and in which order.
///
/// Each queue keeps its own register state, so the draw counter the callback
/// observes says which queue ran the buffer: a second graphics buffer sees two,
/// while the first compute buffer sees one.
const SubmitProbe = struct {
    const gpu_module = @import("gpu");

    marks: [16]u32 = @splat(0),
    counters: [16]u64 = @splat(0),
    mark_count: usize = 0,

    fn from(context: ?*anyopaque) *SubmitProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn read(_: ?*anyopaque, address: u64, bytes: []u8) bool {
        if (address == 0) return false;
        const source: [*]const u8 = @ptrFromInt(address);
        @memcpy(bytes, source[0..bytes.len]);
        return true;
    }

    fn write(_: ?*anyopaque, address: u64, bytes: []const u8) bool {
        if (address == 0) return false;
        const target: [*]u8 = @ptrFromInt(address);
        @memcpy(target[0..bytes.len], bytes);
        return true;
    }

    fn draw(
        context: ?*anyopaque,
        state: *const gpu_module.State,
        packet: gpu_module.pm4.Packet,
    ) bool {
        const self = from(context);
        if (self.mark_count < self.marks.len) {
            self.marks[self.mark_count] = packet.body[0];
            self.counters[self.mark_count] = state.draw_count;
            self.mark_count += 1;
        }
        return true;
    }

    const vtable = gpu_module.DcbBackend.VTable{
        .read = read,
        .write = write,
        .draw = draw,
    };

    fn attach(self: *SubmitProbe) void {
        libs.agc_submit.attachBackend(.{ .context = self, .vtable = &vtable });
    }
};

fn pm4Command(opcode: u8, body_words: u14) u32 {
    return (@as(u32, 3) << 30) | (@as(u32, body_words - 1) << 16) | (@as(u32, opcode) << 8);
}

/// One DRAW_INDEX_AUTO whose index count identifies the buffer it came from.
fn markedDraw(mark: u32) [3]u32 {
    const gpu_module = @import("gpu");
    return .{ pm4Command(gpu_module.pm4.draw_index_auto, 2), mark, 0 };
}

test "SubmitMultiCommandBuffers accepts an empty batch" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const submit = try agcDriverEntryPoint(&db, "Fj7r9EHzF38", SubmitMultiCommandBuffers);

    libs.agc_submit.reset();
    defer libs.agc_submit.reset();

    // A count of zero is answered before the arrays are looked at, so a driver
    // that passes nothing at all is not an error.
    try testing.expectEqual(errno.ok, submit(null, null, null, 0));
}

test "SubmitMultiCommandBuffers refuses a batch missing a required array" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const submit = try agcDriverEntryPoint(&db, "Fj7r9EHzF38", SubmitMultiCommandBuffers);

    libs.agc_submit.reset();
    defer libs.agc_submit.reset();

    var context = [_]u32{ 0, 0 };
    var only = markedDraw(1);
    const buffers = [_]?[*]const u32{&only};
    const sizes = [_]u32{only.len};

    const einval = errno.KernelError.einval.raw();
    try testing.expectEqual(einval, submit(&context, null, &sizes, 1));
    try testing.expectEqual(einval, submit(&context, &buffers, null, 1));
    // The queue identifier lives inside the context, so without one there is no
    // queue to run the batch on.
    try testing.expectEqual(einval, submit(null, &buffers, &sizes, 1));
}

test "SubmitMultiCommandBuffers runs its buffers in the order given" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const submit = try agcDriverEntryPoint(&db, "Fj7r9EHzF38", SubmitMultiCommandBuffers);

    libs.agc_submit.reset();
    defer libs.agc_submit.reset();
    var probe = SubmitProbe{};
    probe.attach();

    var context = [_]u32{ 0, 0 };
    var first = markedDraw(11);
    var second = markedDraw(22);
    var third = markedDraw(33);
    // A hole between buffers must not end the batch.
    const buffers = [_]?[*]const u32{ &first, null, &second, &third };
    const sizes = [_]u32{ first.len, 0, second.len, third.len };

    try testing.expectEqual(errno.ok, submit(&context, &buffers, &sizes, buffers.len));
    try testing.expectEqual(@as(usize, 3), probe.mark_count);
    try testing.expectEqualSlices(u32, &.{ 11, 22, 33 }, probe.marks[0..3]);
}

test "SubmitMultiCommandBuffers routes by the queue its context names" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const submit = try agcDriverEntryPoint(&db, "Fj7r9EHzF38", SubmitMultiCommandBuffers);

    libs.agc_submit.reset();
    defer libs.agc_submit.reset();
    var probe = SubmitProbe{};
    probe.attach();

    // 0x20 is the first compute identifier; 0x10 and 0x58 fall outside the
    // compute block and are graphics work.
    var graphics_context = [_]u32{ 0, 0x10 };
    var compute_context = [_]u32{ 0, 0x20 };
    var past_compute_context = [_]u32{ 0, 0x58 };

    var one = markedDraw(1);
    var two = markedDraw(2);
    var three = markedDraw(3);
    const first = [_]?[*]const u32{&one};
    const second = [_]?[*]const u32{&two};
    const third = [_]?[*]const u32{&three};
    const sizes = [_]u32{one.len};

    try testing.expectEqual(errno.ok, submit(&graphics_context, &first, &sizes, 1));
    try testing.expectEqual(errno.ok, submit(&compute_context, &second, &sizes, 1));
    try testing.expectEqual(errno.ok, submit(&past_compute_context, &third, &sizes, 1));

    try testing.expectEqual(@as(usize, 3), probe.mark_count);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, probe.marks[0..3]);
    // Each queue counts its own work. The compute buffer starts a fresh count,
    // and the second graphics buffer continues the first one, which it could
    // not do if every submission were funnelled onto the DCB queue.
    try testing.expectEqual(@as(u64, 1), probe.counters[0]);
    try testing.expectEqual(@as(u64, 1), probe.counters[1]);
    try testing.expectEqual(@as(u64, 2), probe.counters[2]);
}

test "SubmitMultiCommandBuffers resumes past a wait without replaying it" {
    const std = @import("std");
    const gpu_module = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const submit = try agcDriverEntryPoint(&db, "Fj7r9EHzF38", SubmitMultiCommandBuffers);

    libs.agc_submit.reset();
    defer libs.agc_submit.reset();
    var probe = SubmitProbe{};
    probe.attach();

    // The label the queue parks on. It does not hold the awaited value, so the
    // stream blocks midway and only continues once that value arrives.
    //
    // It lives on the heap rather than beside the buffers: the submit path
    // protects the sixteen bytes ahead of every submitted arena as its
    // allocation header, and a label the stack happened to place there would be
    // recovered by the scheduler instead of through guest memory.
    const label = try testing.allocator.create(u32);
    defer testing.allocator.destroy(label);
    label.* = 0;
    const label_address = @intFromPtr(label);

    var waiting = [_]u32{
        pm4Command(gpu_module.pm4.draw_index_auto, 2),
        44,
        0,
        pm4Command(gpu_module.pm4.wait_reg_mem, 6),
        // Memory space (bit 4), compare "equal" (3).
        0x13,
        @truncate(label_address),
        @truncate(label_address >> 32),
        1,
        0xffff_ffff,
        0x10,
        pm4Command(gpu_module.pm4.draw_index_auto, 2),
        55,
        0,
    };
    var after = markedDraw(66);
    const buffers = [_]?[*]const u32{ &waiting, &after };
    const sizes = [_]u32{ waiting.len, after.len };

    var context = [_]u32{ 0, 0 };
    try testing.expectEqual(errno.ok, submit(&context, &buffers, &sizes, buffers.len));

    // The wait really parked the queue: the value it waited for was not there
    // before the call and is there afterwards.
    try testing.expectEqual(@as(u32, 1), label.*);
    // The draw ahead of the wait ran once, not once per resume attempt, and the
    // rest of the batch followed it in order.
    try testing.expectEqual(@as(usize, 3), probe.mark_count);
    try testing.expectEqualSlices(u32, &.{ 44, 55, 66 }, probe.marks[0..3]);
}

// ---------------------------------------------------------------------------
// AGC size contracts
//
// These go through the registry, because the contract a title sees is the pair
// of functions the dynamic linker hands it: whatever the two halves agree on
// inside one file does not matter if a different entry point is the one that
// gets resolved.
//
// Sizes are checked in BYTES, which is what every GetSize answers in, and
// packet widths in DWORDS, which is what a PM4 header encodes. The conversion
// is written out at each comparison rather than folded into a helper, so a
// mismatched unit shows up in the test as plainly as in the code.

/// A size query. All of them answer in bytes; the fixed-width ones ignore
/// their arguments, so one signature serves the whole family.
const AgcGetSize = fn (u64, u64, u64, u64, u64, u64) callconv(abi.guest) u32;

/// A command constructor. Every one takes the buffer first.
const AgcWrite = fn (
    ?*libs.agc.CommandBuffer,
    u64,
    u64,
    u64,
    u64,
    u64,
) callconv(abi.guest) ?[*]u32;

/// Reads a packet that already exists and answers in dwords.
const AgcPacketSize = fn (?[*]const u32, u64, u64, u64, u64, u64) callconv(abi.guest) u32;

const guard_word: u32 = 0xa5a5_a5a5;

/// A command buffer over `words`, with no grow callback attached.
fn sizedBuffer(words: []u32) libs.agc.CommandBuffer {
    return .{
        .bottom = words.ptr,
        .top = words.ptr + words.len,
        .cursor_up = words.ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
}

const SizeCase = struct {
    what: []const u8,
    size_id: *const [nid.encoded_len:0]u8,
    write_id: *const [nid.encoded_len:0]u8,
    /// Index into `arguments` that must be replaced with a readable address.
    address_argument: ?usize = null,
    arguments: [5]u64,
};

test "every fixed-width AGC command fits the size it reports" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    // Something for the address-taking constructors to point at. The contents
    // are never read by them, only the address.
    var payload: [16]u32 = @splat(0);
    const payload_address = @intFromPtr(&payload);

    const cases = [_]SizeCase{
        .{ .what = "DcbDrawIndex", .size_id = "6ee9Hd3EWXQ", .write_id = "q88lQ+GP5Yk", .address_argument = 1, .arguments = .{ 3, 0, 0, 0, 0 } },
        .{ .what = "DcbDrawIndexAuto", .size_id = "WrdP9Zxx3lQ", .write_id = "Yw0jKSqop+E", .arguments = .{ 3, 0, 0, 0, 0 } },
        .{ .what = "CbDispatch", .size_id = "Abendgtz+3o", .write_id = "k3GhuSNmBLU", .arguments = .{ 1, 1, 1, 0, 0 } },
        .{ .what = "DcbSetIndexBuffer", .size_id = "j4emHHndCPY", .write_id = "l4fM9K-Lyks", .address_argument = 0, .arguments = .{ 0, 0, 0, 0, 0 } },
        .{ .what = "DcbSetIndexCount", .size_id = "mljzuGDZRQ4", .write_id = "8N2tmT3jmC8", .arguments = .{ 3, 0, 0, 0, 0 } },
        .{ .what = "DcbSetIndexSize", .size_id = "ca4KPvp0qLQ", .write_id = "GIIW2J37e70", .arguments = .{ 1, 0, 0, 0, 0 } },
        .{ .what = "DcbSetNumInstances", .size_id = "6DFuRKT4C9w", .write_id = "tSBxhAPyytQ", .arguments = .{ 2, 0, 0, 0, 0 } },
        .{ .what = "DcbSetCxRegistersIndirect", .size_id = "GBCh3zCihoU", .write_id = "ZvwO9euwYzc", .address_argument = 0, .arguments = .{ 0, 4, 0, 0, 0 } },
        .{ .what = "DcbSetCxRegisterDirect", .size_id = "1DeUNpRIDDA", .write_id = "LHFXRrlTPD8", .arguments = .{ (@as(u64, 0x1234) << 32) | 0x318, 0, 0, 0, 0 } },
        .{ .what = "DcbJump", .size_id = "VEGu4dixjUg", .write_id = "xSAR0LTcRKM", .address_argument = 2, .arguments = .{ 0, 0, 0, 4, 0 } },
        .{ .what = "AcbJump", .size_id = "b-oySn+G2tE", .write_id = "e1DFTg+Sd8U", .address_argument = 1, .arguments = .{ 0, 0, 4, 0, 0 } },
        .{ .what = "DcbStallCommandBufferParser", .size_id = "+u6dKSLWM2o", .write_id = "u2T2DiA5hRI", .arguments = .{ 0, 0, 0, 0, 0 } },
    };

    inline for (cases) |case| {
        const get_size = try agcEntryPoint(&db, case.size_id, AgcGetSize);
        const write = try agcEntryPoint(&db, case.write_id, AgcWrite);

        const announced_bytes = get_size(0, 0, 0, 0, 0, 0);
        errdefer std.debug.print("case {s}\n", .{case.what});
        try testing.expect(announced_bytes != 0);
        try testing.expectEqual(@as(u32, 0), announced_bytes % @sizeOf(u32));
        const announced_words = announced_bytes / @sizeOf(u32);

        var arguments = case.arguments;
        if (case.address_argument) |index| arguments[index] = payload_address;

        // A buffer of exactly the announced size, with guard words after it
        // that the command must not reach.
        var storage: [64]u32 = @splat(guard_word);
        var buffer = sizedBuffer(storage[0..announced_words]);

        try testing.expect(write(
            &buffer,
            arguments[0],
            arguments[1],
            arguments[2],
            arguments[3],
            arguments[4],
        ) != null);

        // Exactly filled: the cursor sits at the end of the announced span.
        try testing.expectEqual(
            @as(usize, announced_bytes),
            @intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr),
        );
        for (storage[announced_words..]) |word| try testing.expectEqual(guard_word, word);

        // What landed is one packet of exactly that width, and it says so to a
        // caller stepping over it.
        var walker = gpu.pm4.Walker.init(storage[0..announced_words]);
        const packet = (try walker.next()).?;
        try testing.expectEqual(@as(usize, announced_words), packet.wordCount());
        try testing.expect((try walker.next()) == null);

        // The size was not padded either: one word less is not enough, and a
        // refused write leaves the buffer as it found it.
        var tight: [64]u32 = @splat(guard_word);
        var short = sizedBuffer(tight[0 .. announced_words - 1]);
        try testing.expect(write(
            &short,
            arguments[0],
            arguments[1],
            arguments[2],
            arguments[3],
            arguments[4],
        ) == null);
        for (tight) |word| try testing.expectEqual(guard_word, word);
    }
}

test "AGC event write is sized by the event it carries" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get_size = try agcEntryPoint(&db, "C4l9fB17t8w", AgcGetSize);
    const write = try agcEntryPoint(&db, "aJf+j5yntiU", AgcWrite);

    var label: [2]u32 = @splat(0);
    const label_address = @intFromPtr(&label);

    // The timestamp events carry an address and are twice as wide as the ones
    // that do not, so a single fixed width is wrong for one of the two groups.
    const events = [_]struct { event_type: u64, words: u32 }{
        .{ .event_type = 0x38, .words = 4 },
        .{ .event_type = 0x39, .words = 4 },
        .{ .event_type = 0x04, .words = 2 },
        .{ .event_type = 0x07, .words = 2 },
        .{ .event_type = 0x16, .words = 2 },
    };

    for (events) |event| {
        const announced = get_size(event.event_type, 0, 0, 0, 0, 0);
        try testing.expectEqual(event.words * @sizeOf(u32), announced);

        var storage: [16]u32 = @splat(guard_word);
        var buffer = sizedBuffer(storage[0..event.words]);
        try testing.expect(write(&buffer, event.event_type, label_address, 0, 0, 0) != null);
        try testing.expectEqual(
            @as(usize, announced),
            @intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr),
        );
        for (storage[event.words..]) |word| try testing.expectEqual(guard_word, word);

        var walker = gpu.pm4.Walker.init(storage[0..event.words]);
        const packet = (try walker.next()).?;
        try testing.expectEqual(gpu.pm4.event_write, packet.opcode);
        try testing.expectEqual(@as(usize, event.words), packet.wordCount());
        try testing.expect((try walker.next()) == null);
    }

    // An event the constructor refuses is sized at zero rather than at a width
    // nothing will occupy.
    try testing.expectEqual(@as(u32, 0), get_size(0x40, 0, 0, 0, 0, 0));
}

test "AGC nop is written at the width the caller chose" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get_size = try agcEntryPoint(&db, "t7PlZ9nt5Lc", AgcGetSize);
    const write = try agcEntryPoint(&db, "LtTouSCZjHM", AgcWrite);

    for ([_]u32{ 2, 3, 5, 17, 40 }) |requested| {
        try testing.expectEqual(requested * @sizeOf(u32), get_size(requested, 0, 0, 0, 0, 0));

        var storage: [64]u32 = @splat(guard_word);
        var buffer = sizedBuffer(storage[0..requested]);
        try testing.expect(write(&buffer, requested, 0, 0, 0, 0) != null);
        try testing.expectEqual(
            @as(usize, requested) * @sizeOf(u32),
            @intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr),
        );
        for (storage[requested..]) |word| try testing.expectEqual(guard_word, word);

        var walker = gpu.pm4.Walker.init(storage[0..requested]);
        const packet = (try walker.next()).?;
        try testing.expectEqual(gpu.pm4.nop, packet.opcode);
        try testing.expectEqual(@as(usize, requested), packet.wordCount());
        try testing.expect((try walker.next()) == null);
    }

    // Widths no packet can express are refused by both halves alike, so a
    // caller that sizes first never reserves room for a command that will not
    // appear.
    try testing.expectEqual(@as(u32, 0), get_size(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0), get_size(1, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0), get_size(0x4001, 0, 0, 0, 0, 0));

    var storage: [8]u32 = @splat(guard_word);
    var buffer = sizedBuffer(&storage);
    try testing.expect(write(&buffer, 1, 0, 0, 0, 0) == null);
    for (storage) |word| try testing.expectEqual(guard_word, word);
}

test "GetPacketSize walks a run of packets of differing widths" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const packet_size = try agcEntryPoint(&db, "Lkf86B98qPc", AgcPacketSize);
    const nop = try agcEntryPoint(&db, "LtTouSCZjHM", AgcWrite);
    const set_index_count = try agcEntryPoint(&db, "8N2tmT3jmC8", AgcWrite);
    const draw_auto = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    var storage: [32]u32 = @splat(0);
    var buffer = sizedBuffer(&storage);

    // Two, three and five dwords in a row, so a caller that assumed one width
    // would land inside a packet instead of on the next one.
    try testing.expect(set_index_count(&buffer, 7, 0, 0, 0, 0) != null);
    try testing.expect(draw_auto(&buffer, 3, 0, 0, 0, 0) != null);
    try testing.expect(nop(&buffer, 5, 0, 0, 0, 0) != null);
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr)) / @sizeOf(u32);
    try testing.expectEqual(@as(usize, 2 + 3 + 5), used);

    // Stepping with GetPacketSize alone reaches the same boundaries the command
    // walker does, and lands on the end rather than past it.
    const widths = [_]u32{ 2, 3, 5 };
    var offset: usize = 0;
    var walker = gpu.pm4.Walker.init(storage[0..used]);
    for (widths) |width| {
        const reported = packet_size(storage[offset..].ptr, 0, 0, 0, 0, 0);
        try testing.expectEqual(width, reported);
        const packet = (try walker.next()).?;
        try testing.expectEqual(@as(usize, width), packet.wordCount());
        offset += reported;
    }
    try testing.expectEqual(used, offset);
    try testing.expect((try walker.next()) == null);

    // Alignment filler carries no body and is one dword, whatever follows it.
    var padded = [_]u32{ @as(u32, 2) << 30, 0, 0 };
    try testing.expectEqual(@as(u32, 1), packet_size(padded[0..].ptr, 0, 0, 0, 0, 0));

    // A packet that cannot be read is answered with zero, not with a guess.
    try testing.expectEqual(@as(u32, 0), packet_size(null, 0, 0, 0, 0, 0));
}

/// The arena the grow callback hands over, and the count of times it ran.
var grow_arena: []u32 = &.{};
var grow_calls: u32 = 0;

/// Stands in for the CPU backend that would dispatch the title's callback.
///
/// `reserveDwords` calls the guest with the buffer, the dwords still needed and
/// the user data. A real title attaches another arena and returns non-zero;
/// this does the same thing directly, which is enough to exercise the branch in
/// `reserveDwords` that decides whether the write may proceed.
fn growCall(_: ?*anyopaque, request: libs.kernel_threading.GuestCall) libs.kernel_threading.BackendError!u64 {
    grow_calls += 1;
    if (request.argument_count < 2) return 0;
    const buffer: *libs.agc.CommandBuffer = @ptrFromInt(request.arguments[0]);
    const needed = request.arguments[1];
    if (needed > grow_arena.len) return 0;
    buffer.bottom = grow_arena.ptr;
    buffer.top = grow_arena.ptr + grow_arena.len;
    buffer.cursor_up = grow_arena.ptr;
    buffer.cursor_down = null;
    return 1;
}

fn growStart(_: ?*anyopaque, _: libs.kernel_threading.StartRequest) libs.kernel_threading.BackendError!void {
    return error.Unsupported;
}

test "a command larger than its arena is written after the grow callback" {
    const std = @import("std");
    const gpu = @import("gpu");
    const threading = libs.kernel_threading;
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get_size = try agcEntryPoint(&db, "t7PlZ9nt5Lc", AgcGetSize);
    const write = try agcEntryPoint(&db, "LtTouSCZjHM", AgcWrite);

    var second: [16]u32 = @splat(guard_word);
    grow_arena = &second;
    grow_calls = 0;

    var manager = threading.Manager{};
    manager.backend = .{ .context = null, .start_fn = growStart, .call_fn = growCall };
    threading.attachManager(&manager);
    defer threading.attachManager(null);

    const requested: u32 = 12;
    const announced = get_size(requested, 0, 0, 0, 0, 0);
    try testing.expectEqual(requested * @sizeOf(u32), announced);

    // An arena with room for four dwords, asked for twelve.
    var first: [4]u32 = @splat(guard_word);
    var buffer = sizedBuffer(&first);
    buffer.callback = @ptrFromInt(0x1000);

    try testing.expect(write(&buffer, requested, 0, 0, 0, 0) != null);
    try testing.expectEqual(@as(u32, 1), grow_calls);

    // The command landed in the arena the callback attached, at its full width,
    // and the arena it would not fit in was left untouched.
    try testing.expectEqual(
        @as(usize, announced),
        @intFromPtr(buffer.cursor_up.?) - @intFromPtr(second[0..].ptr),
    );
    for (first) |word| try testing.expectEqual(guard_word, word);
    for (second[requested..]) |word| try testing.expectEqual(guard_word, word);

    var walker = gpu.pm4.Walker.init(second[0..requested]);
    const packet = (try walker.next()).?;
    try testing.expectEqual(gpu.pm4.nop, packet.opcode);
    try testing.expectEqual(@as(usize, requested), packet.wordCount());

    // A callback that cannot satisfy the request refuses the write rather than
    // letting it run past the end of the arena it has.
    grow_arena = second[0..4];
    grow_calls = 0;
    var tight: [4]u32 = @splat(guard_word);
    var tight_buffer = sizedBuffer(&tight);
    tight_buffer.callback = @ptrFromInt(0x1000);
    try testing.expect(write(&tight_buffer, requested, 0, 0, 0, 0) == null);
    try testing.expectEqual(@as(u32, 1), grow_calls);
    for (tight) |word| try testing.expectEqual(guard_word, word);

    grow_arena = &.{};
}

test "a direct register list never writes past the size it was given" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get_size = try agcEntryPoint(&db, "yUBESvCCJ4I", AgcGetSize);
    const write = try agcEntryPoint(&db, "UZbQjYAwwXM", AgcWrite);

    const Register = extern struct { offset: u32, value: u32 };

    // One ascending run costs the least, and a list with no two neighbours
    // adjacent costs the most. The query cannot see which it was handed, so it
    // has to cover the worse of the two.
    const consecutive = [_]Register{
        .{ .offset = 0x100, .value = 1 },
        .{ .offset = 0x101, .value = 2 },
        .{ .offset = 0x102, .value = 3 },
        .{ .offset = 0x103, .value = 4 },
    };
    const scattered = [_]Register{
        .{ .offset = 0x100, .value = 1 },
        .{ .offset = 0x200, .value = 2 },
        .{ .offset = 0x300, .value = 3 },
        .{ .offset = 0x400, .value = 4 },
    };

    const announced = get_size(consecutive.len, 0, 0, 0, 0, 0);
    try testing.expectEqual(@as(u32, consecutive.len * 3 * @sizeOf(u32)), announced);
    const announced_words = announced / @sizeOf(u32);

    for ([_][]const Register{ &consecutive, &scattered }) |list| {
        var storage: [64]u32 = @splat(guard_word);
        var buffer = sizedBuffer(storage[0..announced_words]);
        try testing.expect(write(&buffer, @intFromPtr(list.ptr), list.len, 0, 0, 0) != null);

        const used = @intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr);
        // Never more than announced, and the guard words past the announced
        // span are untouched whichever shape the list had.
        try testing.expect(used <= announced);
        for (storage[announced_words..]) |word| try testing.expectEqual(guard_word, word);

        // Whatever it wrote is a walkable run of complete packets.
        var walker = gpu.pm4.Walker.init(storage[0 .. used / @sizeOf(u32)]);
        var seen: usize = 0;
        while (try walker.next()) |packet| {
            try testing.expectEqual(gpu.pm4.set_sh_reg, packet.opcode);
            seen += packet.wordCount();
        }
        try testing.expectEqual(used / @sizeOf(u32), seen);
    }

    // The scattered list is the one that needs the whole reservation; the
    // consecutive one needs less. That is the spread the query has to cover.
    var compact: [64]u32 = @splat(guard_word);
    var compact_buffer = sizedBuffer(compact[0..announced_words]);
    try testing.expect(write(&compact_buffer, @intFromPtr(&consecutive), consecutive.len, 0, 0, 0) != null);
    const compact_used = @intFromPtr(compact_buffer.cursor_up.?) - @intFromPtr(compact[0..].ptr);
    try testing.expectEqual(@as(usize, (consecutive.len + 2) * @sizeOf(u32)), compact_used);
    try testing.expect(compact_used < announced);

    // Counts the constructor refuses are sized at zero.
    try testing.expectEqual(@as(u32, 0), get_size(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0), get_size(0x1001, 0, 0, 0, 0, 0));
}

// ---------------------------------------------------------------------------
// Predication
//
// A title sets a predicate, marks the packets it guards, and expects the ones
// it guarded to disappear when the predicate says so. These go through the
// registry for the constructor half and drive the executor directly for the
// execution half, because the two are only useful together.

const AgcPatch2 = fn (?[*]u32, u64, u64, u64, u64, u64) callconv(abi.guest) i32;
const AgcRangePatch = fn (?[*]u32, ?[*]const u32, u64, u64, u64, u64) callconv(abi.guest) i32;

/// Serves reads straight out of host memory, which is where a test's predicate
/// lives, and records what reached the renderer.
const PredicationProbe = struct {
    const gpu_module = @import("gpu");

    draws: u32 = 0,
    dispatches: u32 = 0,
    events: [16]u8 = @splat(0),
    event_count: usize = 0,

    fn from(context: ?*anyopaque) *PredicationProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn read(_: ?*anyopaque, address: u64, bytes: []u8) bool {
        if (address == 0) return false;
        const source: [*]const u8 = @ptrFromInt(address);
        @memcpy(bytes, source[0..bytes.len]);
        return true;
    }

    fn write(_: ?*anyopaque, address: u64, bytes: []const u8) bool {
        if (address == 0) return false;
        const target: [*]u8 = @ptrFromInt(address);
        @memcpy(target[0..bytes.len], bytes);
        return true;
    }

    fn draw(context: ?*anyopaque, _: *const gpu_module.State, _: gpu_module.pm4.Packet) bool {
        from(context).draws += 1;
        return true;
    }

    fn dispatch(context: ?*anyopaque, _: *const gpu_module.State, _: gpu_module.pm4.Packet) bool {
        from(context).dispatches += 1;
        return true;
    }

    fn event(context: ?*anyopaque, value: gpu_module.state.EventWrite) bool {
        const self = from(context);
        if (self.event_count < self.events.len) {
            self.events[self.event_count] = value.event_type;
            self.event_count += 1;
        }
        return true;
    }

    const vtable = gpu_module.DcbBackend.VTable{
        .read = read,
        .write = write,
        .event = event,
        .draw = draw,
        .dispatch = dispatch,
    };

    fn backend(self: *PredicationProbe) gpu_module.DcbBackend {
        return .{ .context = self, .vtable = &vtable };
    }
};

/// Builds one SET_PREDICATION packet through the registered constructor, so the
/// bits the executor decodes are the bits the library actually writes.
fn buildPredication(
    db: *const Database,
    buffer: *libs.agc.CommandBuffer,
    condition: u64,
    op: u64,
    wait_op: u64,
    address: u64,
) !void {
    const write = try agcEntryPoint(db, "bbFueFP+J4k", AgcWrite);
    const std = @import("std");
    if (write(buffer, condition, op, wait_op, address, 0) == null) return error.PredicationRefused;
    _ = std;
}

/// Runs one stream on a fresh executor and reports what the backend saw.
fn runPredicated(
    probe: *PredicationProbe,
    state: *@import("gpu").State,
    stream: []const u32,
) !@import("gpu").executor.Result {
    const gpu_module = @import("gpu");
    const std = @import("std");
    var runner = gpu_module.DcbExecutor{
        .state = state,
        .backend = probe.backend(),
        .allocator = std.testing.allocator,
    };
    return runner.execute(stream);
}

test "a boolean predicate drops the packets it guards and keeps the rest" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);

    // Sixteen-byte aligned, as the packet format requires.
    var predicate: [4]u64 align(16) = @splat(0);
    const predicate_address = @intFromPtr(&predicate);

    // condition 0 means: skip the guarded packets when the value is non-zero.
    for ([_]struct { value: u64, guarded_runs: bool }{
        .{ .value = 0, .guarded_runs = true },
        .{ .value = 1, .guarded_runs = false },
        .{ .value = 0xffff_ffff_ffff_ffff, .guarded_runs = false },
    }) |trial| {
        predicate[0] = trial.value;

        var words: [32]u32 = @splat(0);
        var buffer = sizedBuffer(&words);
        try buildPredication(&db, &buffer, 0, 3, 0, predicate_address);

        const guarded = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);
        const guarded_packet = guarded(&buffer, 3, 0, 0, 0, 0).?;
        try testing.expectEqual(errno.ok, mark(guarded_packet, 1, 0, 0, 0, 0));

        // An unguarded draw after it, which must run whatever the predicate says.
        _ = guarded(&buffer, 4, 0, 0, 0, 0).?;

        const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
        var probe = PredicationProbe{};
        var state = gpu.State{};
        _ = try runPredicated(&probe, &state, words[0..used]);

        try testing.expectEqual(@as(u32, if (trial.guarded_runs) 2 else 1), probe.draws);
        try testing.expectEqual(trial.value != 0, state.predicate_skip);
        try testing.expectEqual(@as(u64, 1), state.predication_enable_count);
    }
}

test "the predicate condition inverts which way the guard runs" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    var predicate: [4]u64 align(16) = @splat(0);
    const predicate_address = @intFromPtr(&predicate);

    // condition 1 skips when the value is zero, which is the opposite of
    // condition 0 for the same value.
    for ([_]u64{ 0, 1 }) |value| {
        for ([_]u64{ 0, 1 }) |condition| {
            predicate[0] = value;

            var words: [32]u32 = @splat(0);
            var buffer = sizedBuffer(&words);
            try buildPredication(&db, &buffer, condition, 3, 0, predicate_address);
            const guarded_packet = draw(&buffer, 3, 0, 0, 0, 0).?;
            try testing.expectEqual(errno.ok, mark(guarded_packet, 1, 0, 0, 0, 0));

            const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
            var probe = PredicationProbe{};
            var state = gpu.State{};
            _ = try runPredicated(&probe, &state, words[0..used]);

            const skipped = if (condition == 0) value != 0 else value == 0;
            try testing.expectEqual(skipped, state.predicate_skip);
            try testing.expectEqual(@as(u32, if (skipped) 0 else 1), probe.draws);
        }
    }
}

test "disabling predication lets the guarded packets through again" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    var predicate: [4]u64 align(16) = @splat(1);
    const predicate_address = @intFromPtr(&predicate);

    var words: [64]u32 = @splat(0);
    var buffer = sizedBuffer(&words);

    // Guarded while the predicate says skip ...
    try buildPredication(&db, &buffer, 0, 3, 0, predicate_address);
    try testing.expectEqual(errno.ok, mark(draw(&buffer, 3, 0, 0, 0, 0).?, 1, 0, 0, 0, 0));
    // ... then predication is turned off, and the same guarded packet runs.
    try buildPredication(&db, &buffer, 0, 0, 0, 0);
    try testing.expectEqual(errno.ok, mark(draw(&buffer, 4, 0, 0, 0, 0).?, 1, 0, 0, 0, 0));

    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    try testing.expectEqual(@as(u32, 1), probe.draws);
    try testing.expect(!state.predicate_skip);
    try testing.expectEqual(@as(u64, 1), state.predication_enable_count);
    try testing.expectEqual(@as(u64, 1), state.predication_disable_count);
    try testing.expectEqual(@as(u64, 1), state.predicated_skipped);
    try testing.expectEqual(@as(u64, 1), state.predicated_executed);
}

test "the predicate is read after the command that writes it, not before" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);
    // WRITE_DATA takes eight arguments, and the last two decide whether the
    // words land at one address or at consecutive ones -- it cannot be called
    // through the six-argument shape the other constructors share.
    const WriteData = fn (
        ?*libs.agc.CommandBuffer,
        u32,
        u32,
        u64,
        ?[*]align(1) const u32,
        u32,
        u32,
        u32,
    ) callconv(abi.guest) ?[*]u32;
    const write_data = try agcEntryPoint(&db, "i1jyy49AjXU", WriteData);

    // Starts at zero, so a predicate read before the stream ran would let the
    // guarded draw through. The WRITE_DATA ahead of SET_PREDICATION sets it.
    var predicate: [4]u64 align(16) = @splat(0);
    const predicate_address = @intFromPtr(&predicate);

    var words: [64]u32 = @splat(0);
    var buffer = sizedBuffer(&words);

    const payload = [_]u32{1};
    // Destination five is memory; five ones say "write one dword, at this
    // address, and do not wait for confirmation".
    _ = write_data(&buffer, 5, 0, predicate_address, &payload, 1, 0, 0).?;
    try buildPredication(&db, &buffer, 0, 3, 0, predicate_address);
    try testing.expectEqual(errno.ok, mark(draw(&buffer, 3, 0, 0, 0, 0).?, 1, 0, 0, 0, 0));

    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    try testing.expectEqual(@as(u64, 1), predicate[0]);
    try testing.expect(state.predicate_skip);
    try testing.expectEqual(@as(u32, 0), probe.draws);
}

test "range predication marks whole packets and only the flag bit" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const range = try agcEntryPoint(&db, "n8vgpaQg6dA", AgcRangePatch);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);
    const set_count = try agcEntryPoint(&db, "8N2tmT3jmC8", AgcWrite);
    const nop = try agcEntryPoint(&db, "LtTouSCZjHM", AgcWrite);

    var words: [64]u32 = @splat(0);
    var buffer = sizedBuffer(&words);

    // Three packets of different widths, so a word-by-word walk would set the
    // flag inside a payload rather than on a header.
    _ = set_count(&buffer, 7, 0, 0, 0, 0).?;
    _ = draw(&buffer, 3, 0, 0, 0, 0).?;
    _ = nop(&buffer, 5, 0, 0, 0, 0).?;
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    try testing.expectEqual(@as(usize, 10), used);

    const before = words;
    const headers = [_]usize{ 0, 2, 5 };

    try testing.expectEqual(errno.ok, range(words[0..].ptr, words[used..].ptr, 1, 0, 0, 0));
    for (words[0..used], 0..) |word, index| {
        const is_header = std.mem.indexOfScalar(usize, &headers, index) != null;
        if (is_header) {
            try testing.expectEqual(before[index] | 1, word);
        } else {
            try testing.expectEqual(before[index], word);
        }
    }

    // Clearing the range restores every header exactly.
    try testing.expectEqual(errno.ok, range(words[0..].ptr, words[used..].ptr, 0, 0, 0, 0));
    for (words[0..used], 0..) |word, index| try testing.expectEqual(before[index], word);

    // A span that does not divide into whole packets is refused before it
    // writes anything.
    try testing.expectEqual(
        errno.KernelError.einval.raw(),
        range(words[0..].ptr, words[used - 1 ..].ptr, 1, 0, 0, 0),
    );
    for (words[0..used], 0..) |word, index| try testing.expectEqual(before[index], word);

    // An empty span is not an error, and a reversed one is.
    try testing.expectEqual(errno.ok, range(words[0..].ptr, words[0..].ptr, 1, 0, 0, 0));
    try testing.expectEqual(
        errno.KernelError.einval.raw(),
        range(words[2..].ptr, words[0..].ptr, 1, 0, 0, 0),
    );
}

test "marking one packet leaves the rest of its header alone" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    var words: [16]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    const packet = draw(&buffer, 3, 0, 0, 0, 0).?;
    const original = words[0];

    try testing.expectEqual(errno.ok, mark(packet, 1, 0, 0, 0, 0));
    try testing.expectEqual(original | 1, words[0]);
    try testing.expectEqual(errno.ok, mark(packet, 0, 0, 0, 0, 0));
    try testing.expectEqual(original & ~@as(u32, 1), words[0]);
    // Setting it twice is not cumulative, and the body is never touched.
    try testing.expectEqual(errno.ok, mark(packet, 1, 0, 0, 0, 0));
    try testing.expectEqual(errno.ok, mark(packet, 1, 0, 0, 0, 0));
    try testing.expectEqual(original | 1, words[0]);
    try testing.expectEqual(@as(u32, 3), words[1]);

    try testing.expectEqual(errno.KernelError.einval.raw(), mark(null, 1, 0, 0, 0, 0));
}

test "packet predication preserves register addresses and alignment words" {
    const std = @import("std");
    const testing = std.testing;
    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);

    for ([_]u32{ 0x0000_2000, 0x0000_2001, 0x8000_0000, 0x8000_0001, 0xffff_1000 }) |header| {
        var words = [_]u32{ header, 0xdead_beef };
        const before = words;
        for ([_]u64{ 1, 0, 1 }) |flag| {
            try testing.expectEqual(errno.ok, mark(&words, flag, 0, 0, 0, 0));
            try testing.expectEqualSlices(u32, &before, &words);
        }
    }

    var reserved = [_]u32{ 0x4000_0000, 0xdead_beef };
    const before = reserved;
    try testing.expectEqual(errno.KernelError.einval.raw(), mark(&reserved, 1, 0, 0, 0, 0));
    try testing.expectEqualSlices(u32, &before, &reserved);
}

test "range predication keeps mixed streams walkable and marks commands after padding" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;
    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const range = try agcEntryPoint(&db, "n8vgpaQg6dA", AgcRangePatch);

    // Special padding at the beginning, middle and end; ordinary type-2
    // padding; and an odd type-0 register address that clearing bit zero
    // would change. A payload word also looks like the special filler.
    var words = [_]u32{
        0xffff_1000,
        pm4Command(gpu.pm4.draw_index_auto, 2),
        3,
        0,
        0x8000_0000,
        0x0000_2001,
        0xffff_1000,
        0xffff_1000,
        pm4Command(gpu.pm4.num_instances, 1) | 1,
        2,
        0xffff_1000,
    };
    const before = words;
    for ([_]u64{ 1, 0, 1, 1 }) |flag| {
        try testing.expectEqual(errno.ok, range(&words, words[words.len..].ptr, flag, 0, 0, 0));
        for (words, 0..) |word, index| {
            const expected = if (index == 1 or index == 8)
                (before[index] & ~@as(u32, 1)) | @as(u32, @intCast(flag))
            else
                before[index];
            try testing.expectEqual(expected, word);
        }
        var walker = gpu.pm4.Walker.init(&words);
        var packet_count: usize = 0;
        while (try walker.next()) |_| packet_count += 1;
        try testing.expectEqual(@as(usize, 7), packet_count);
        try testing.expectEqual(words.len, walker.index);
    }
}

test "range predication refuses malformed tails before changing earlier headers" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;
    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const range = try agcEntryPoint(&db, "n8vgpaQg6dA", AgcRangePatch);

    // The tail is either reserved type-1 or a draw missing its final word.
    for ([_]u32{ 0x4000_0000, pm4Command(gpu.pm4.draw_index_auto, 2) }) |tail| {
        for ([_]u32{ 0, 1 }) |flag| {
            var words = [_]u32{ pm4Command(gpu.pm4.num_instances, 1) | (flag ^ 1), 2, tail, 3 };
            const before = words;
            try testing.expectEqual(
                errno.KernelError.einval.raw(),
                range(&words, words[words.len..].ptr, flag, 0, 0, 0),
            );
            try testing.expectEqualSlices(u32, &before, &words);
        }
    }
}

test "an unsupported predication mode is reported and issues its packets" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    var results: [32]u64 align(16) = @splat(0);

    var words: [32]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    // Occlusion-query predication, which nothing here produces results for.
    try buildPredication(&db, &buffer, 0, 1, 0, @intFromPtr(&results));
    try testing.expectEqual(errno.ok, mark(draw(&buffer, 3, 0, 0, 0, 0).?, 1, 0, 0, 0, 0));

    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    // Counted as unsupported, and the guarded draw issues rather than
    // disappearing with nothing to explain it.
    try testing.expectEqual(@as(u64, 1), state.predication_unsupported_count);
    try testing.expectEqual(@as(u64, 0), state.predication_enable_count);
    try testing.expect(!state.predicate_skip);
    try testing.expectEqual(@as(u32, 1), probe.draws);
}

test "predication carries into a nested indirect buffer and survives CLEAR_STATE" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);
    const jump = try agcEntryPoint(&db, "xSAR0LTcRKM", AgcWrite);
    const reset = try agcEntryPoint(&db, "TRO721eVt4g", AgcWrite);

    var predicate: [4]u64 align(16) = @splat(1);
    const predicate_address = @intFromPtr(&predicate);

    // The child buffer: one guarded draw and one unguarded one.
    var child: [16]u32 = @splat(0);
    var child_buffer = sizedBuffer(&child);
    try testing.expectEqual(errno.ok, mark(draw(&child_buffer, 3, 0, 0, 0, 0).?, 1, 0, 0, 0, 0));
    _ = draw(&child_buffer, 4, 0, 0, 0, 0).?;
    const child_words = (@intFromPtr(child_buffer.cursor_up.?) - @intFromPtr(child[0..].ptr)) / @sizeOf(u32);

    var words: [64]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    try buildPredication(&db, &buffer, 0, 3, 0, predicate_address);
    // CLEAR_STATE drops the register files; it must not drop the predicate.
    _ = reset(&buffer, 0, 1, 0, 0, 0).?;
    _ = jump(&buffer, 0, 0, @intFromPtr(&child), child_words, 0).?;
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    // Only the unguarded child draw ran.
    try testing.expectEqual(@as(u32, 1), probe.draws);
    try testing.expect(state.predicate_skip);
    try testing.expectEqual(@as(u64, 1), state.predicated_skipped);
}

test "a guarded indirect buffer is not descended into" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);
    const jump = try agcEntryPoint(&db, "xSAR0LTcRKM", AgcWrite);

    var predicate: [4]u64 align(16) = @splat(1);

    var child: [16]u32 = @splat(0);
    var child_buffer = sizedBuffer(&child);
    _ = draw(&child_buffer, 3, 0, 0, 0, 0).?;
    _ = draw(&child_buffer, 4, 0, 0, 0, 0).?;
    const child_words = (@intFromPtr(child_buffer.cursor_up.?) - @intFromPtr(child[0..].ptr)) / @sizeOf(u32);

    var words: [64]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    try buildPredication(&db, &buffer, 0, 3, 0, @intFromPtr(&predicate));
    const jump_packet = jump(&buffer, 0, 0, @intFromPtr(&child), child_words, 0).?;
    try testing.expectEqual(errno.ok, mark(jump_packet, 1, 0, 0, 0, 0));
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    // Neither child draw ran: the jump itself was guarded.
    try testing.expectEqual(@as(u32, 0), probe.draws);
    try testing.expectEqual(@as(u64, 0), state.indirect_buffer_count);
}

test "predication counters can be switched off" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    var predicate: [4]u64 align(16) = @splat(1);

    var words: [32]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    try buildPredication(&db, &buffer, 0, 3, 0, @intFromPtr(&predicate));
    try testing.expectEqual(errno.ok, mark(draw(&buffer, 3, 0, 0, 0, 0).?, 1, 0, 0, 0, 0));
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    gpu.executor.setPredicationStatsEnabled(false);
    defer gpu.executor.setPredicationStatsEnabled(true);

    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    // The guard still works; only the bookkeeping is gone.
    try testing.expectEqual(@as(u32, 0), probe.draws);
    try testing.expect(state.predicate_skip);
    try testing.expectEqual(@as(u64, 0), state.predication_enable_count);
    try testing.expectEqual(@as(u64, 0), state.predicated_skipped);
}

// ---------------------------------------------------------------------------
// COPY_DATA
//
// The graphics and compute constructors describe the same transfer with
// different numbers, because the graphics control word carries a parser
// selector the compute one has no room for. These check that the two spellings
// meet in the packet, and that what the packet says is what gets moved.

const AgcCopyData = fn (
    ?*libs.agc.CommandBuffer,
    u64,
    u64,
    u64,
    u64,
    u64,
    u64,
    u64,
    u64,
) callconv(abi.guest) ?[*]u32;

/// Selector spellings that mean the same thing to each queue.
const memory_selector_dcb: u64 = 4;
const memory_selector_acb: u64 = 2;
const immediate_selector_dcb: u64 = 10;
const immediate_selector_acb: u64 = 5;

test "both COPY_DATA constructors reach the registry and agree on the packet" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const dcb = try agcEntryPoint(&db, "1rZSWUv1IRc", AgcCopyData);
    const acb = try agcEntryPoint(&db, "qzMN2XKGA4k", AgcCopyData);
    const dcb_size = try agcEntryPoint(&db, "b5u0Jzm8TF8", AgcGetSize);
    const acb_size = try agcEntryPoint(&db, "CbQh3DKMSno", AgcGetSize);

    try testing.expectEqual(@as(u32, 24), dcb_size(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 24), acb_size(0, 0, 0, 0, 0, 0));

    var graphics: [8]u32 = @splat(0);
    var compute: [8]u32 = @splat(0);
    var graphics_buffer = sizedBuffer(&graphics);
    var compute_buffer = sizedBuffer(&compute);

    const source_address: u64 = 0x1_0000_2000;
    const destination_address: u64 = 0x2_0000_4000;

    try testing.expect(dcb(
        &graphics_buffer,
        memory_selector_dcb,
        1,
        destination_address,
        memory_selector_dcb,
        2,
        source_address,
        1,
        1,
    ) != null);
    try testing.expect(acb(
        &compute_buffer,
        memory_selector_acb,
        1,
        destination_address,
        memory_selector_acb,
        2,
        source_address,
        1,
        1,
    ) != null);

    // The spellings differ; the packet does not.
    try testing.expectEqualSlices(u32, graphics[0..6], compute[0..6]);
    try testing.expectEqual(@as(usize, 6 * @sizeOf(u32)), @intFromPtr(graphics_buffer.cursor_up.?) - @intFromPtr(graphics[0..].ptr));

    var walker = gpu.pm4.Walker.init(graphics[0..6]);
    const packet = (try walker.next()).?;
    try testing.expectEqual(gpu.pm4.copy_data, packet.opcode);
    try testing.expectEqual(@as(usize, 6), packet.wordCount());

    // Source and destination pairs, in that order.
    try testing.expectEqual(@as(u32, @truncate(source_address)), graphics[2]);
    try testing.expectEqual(@as(u32, @truncate(source_address >> 32)), graphics[3]);
    try testing.expectEqual(@as(u32, @truncate(destination_address)), graphics[4]);
    try testing.expectEqual(@as(u32, @truncate(destination_address >> 32)), graphics[5]);

    // Cache policies, item size and write-confirm sit where the packet says.
    const control = graphics[1];
    try testing.expectEqual(@as(u32, 2), (control >> 13) & 0x3);
    try testing.expectEqual(@as(u32, 1), (control >> 16) & 0x1);
    try testing.expectEqual(@as(u32, 1), (control >> 20) & 0x1);
    try testing.expectEqual(@as(u32, 1), (control >> 25) & 0x3);
}

test "COPY_DATA moves four and eight bytes of memory" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const dcb = try agcEntryPoint(&db, "1rZSWUv1IRc", AgcCopyData);
    const acb = try agcEntryPoint(&db, "qzMN2XKGA4k", AgcCopyData);

    for ([_]u64{ 0, 1 }) |item_size| {
        const width: usize = if (item_size == 0) 4 else 8;
        // Both queues, to prove the decode reads either spelling.
        for ([_]struct { write: *const AgcCopyData, selector: u64 }{
            .{ .write = dcb, .selector = memory_selector_dcb },
            .{ .write = acb, .selector = memory_selector_acb },
        }) |form| {
            var source: [2]u32 = .{ 0x1122_3344, 0x5566_7788 };
            var destination: [4]u32 = @splat(0xdead_beef);

            var words: [16]u32 = @splat(0);
            var buffer = sizedBuffer(&words);
            try testing.expect(form.write(
                &buffer,
                form.selector,
                0,
                @intFromPtr(&destination),
                form.selector,
                0,
                @intFromPtr(&source),
                item_size,
                0,
            ) != null);
            const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

            var probe = PredicationProbe{};
            var state = gpu.State{};
            _ = try runPredicated(&probe, &state, words[0..used]);

            try testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(source[0..])[0..width],
                std.mem.sliceAsBytes(destination[0..])[0..width],
            );
            // Nothing beyond the transfer width is touched.
            try testing.expectEqual(@as(u32, 0xdead_beef), destination[2]);
            try testing.expectEqual(@as(u32, 0xdead_beef), destination[3]);
            if (width == 4) try testing.expectEqual(@as(u32, 0xdead_beef), destination[1]);
            try testing.expectEqual(@as(u64, 1), state.copy_data_count);
            try testing.expectEqual(@as(u64, 0), state.copy_data_unsupported_count);
        }
    }
}

test "a COPY_DATA immediate carries its whole value" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const dcb = try agcEntryPoint(&db, "1rZSWUv1IRc", AgcCopyData);
    const acb = try agcEntryPoint(&db, "qzMN2XKGA4k", AgcCopyData);

    const immediate: u64 = 0x0123_4567_89ab_cdef;

    // Each queue names its memory destination its own way too, so the pair
    // travels together.
    for ([_]struct { write: *const AgcCopyData, selector: u64, memory: u64 }{
        .{ .write = dcb, .selector = immediate_selector_dcb, .memory = memory_selector_dcb },
        .{ .write = acb, .selector = immediate_selector_acb, .memory = memory_selector_acb },
    }) |form| {
        // Thirty-two bits: the low half only, written once.
        var narrow: [2]u32 = @splat(0xdead_beef);
        var words: [16]u32 = @splat(0);
        var buffer = sizedBuffer(&words);
        try testing.expect(form.write(
            &buffer,
            form.memory,
            0,
            @intFromPtr(&narrow),
            form.selector,
            0,
            immediate,
            0,
            0,
        ) != null);
        var used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
        var probe = PredicationProbe{};
        var state = gpu.State{};
        _ = try runPredicated(&probe, &state, words[0..used]);
        try testing.expectEqual(@as(u32, @truncate(immediate)), narrow[0]);
        try testing.expectEqual(@as(u32, 0xdead_beef), narrow[1]);

        // Sixty-four bits: the value itself, not the low half twice. That
        // repetition is DMA_DATA's behaviour for a 32-bit pattern, and it is
        // the difference between the two packets.
        var wide: [4]u32 = @splat(0xdead_beef);
        words = @splat(0);
        buffer = sizedBuffer(&words);
        try testing.expect(form.write(
            &buffer,
            form.memory,
            0,
            @intFromPtr(&wide),
            form.selector,
            0,
            immediate,
            1,
            0,
        ) != null);
        used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
        probe = PredicationProbe{};
        state = gpu.State{};
        _ = try runPredicated(&probe, &state, words[0..used]);
        try testing.expectEqual(
            immediate,
            std.mem.readInt(u64, std.mem.sliceAsBytes(wide[0..])[0..8], .little),
        );
        try testing.expect(wide[0] != wide[1]);
        try testing.expectEqual(@as(u32, 0xdead_beef), wide[2]);
    }
}

test "COPY_DATA fits the size it reports" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const dcb = try agcEntryPoint(&db, "1rZSWUv1IRc", AgcCopyData);
    const get_size = try agcEntryPoint(&db, "b5u0Jzm8TF8", AgcGetSize);

    const announced = get_size(0, 0, 0, 0, 0, 0);
    const announced_words = announced / @sizeOf(u32);

    var source: [2]u32 = @splat(1);
    var destination: [2]u32 = @splat(0);

    var storage: [32]u32 = @splat(guard_word);
    var buffer = sizedBuffer(storage[0..announced_words]);
    try testing.expect(dcb(
        &buffer,
        memory_selector_dcb,
        0,
        @intFromPtr(&destination),
        memory_selector_dcb,
        0,
        @intFromPtr(&source),
        0,
        0,
    ) != null);
    try testing.expectEqual(
        @as(usize, announced),
        @intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr),
    );
    for (storage[announced_words..]) |word| try testing.expectEqual(guard_word, word);

    // One word short is refused, and refusing writes nothing.
    var tight: [32]u32 = @splat(guard_word);
    var short = sizedBuffer(tight[0 .. announced_words - 1]);
    try testing.expect(dcb(
        &short,
        memory_selector_dcb,
        0,
        @intFromPtr(&destination),
        memory_selector_dcb,
        0,
        @intFromPtr(&source),
        0,
        0,
    ) == null);
    for (tight) |word| try testing.expectEqual(guard_word, word);
}

test "a guarded COPY_DATA does not copy" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const dcb = try agcEntryPoint(&db, "1rZSWUv1IRc", AgcCopyData);
    const mark = try agcEntryPoint(&db, "w6Dj1VJt5qY", AgcPatch2);

    var predicate: [4]u64 align(16) = @splat(1);
    var source: [2]u32 = .{ 0xcafe_f00d, 0 };
    var destination: [2]u32 = @splat(0xdead_beef);

    var words: [32]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    try buildPredication(&db, &buffer, 0, 3, 0, @intFromPtr(&predicate));
    const packet = dcb(
        &buffer,
        memory_selector_dcb,
        0,
        @intFromPtr(&destination),
        memory_selector_dcb,
        0,
        @intFromPtr(&source),
        0,
        0,
    ).?;
    try testing.expectEqual(errno.ok, mark(packet, 1, 0, 0, 0, 0));
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    // The guard dropped the packet before it was decoded, so nothing moved and
    // nothing was counted as a transfer.
    try testing.expectEqual(@as(u32, 0xdead_beef), destination[0]);
    try testing.expectEqual(@as(u64, 0), state.copy_data_count);
    try testing.expectEqual(@as(u64, 1), state.predicated_skipped);
}

test "a COPY_DATA this does not move yet copies nothing and says so" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const dcb = try agcEntryPoint(&db, "1rZSWUv1IRc", AgcCopyData);

    var source: [2]u32 = .{ 0xcafe_f00d, 0 };
    var destination: [2]u32 = @splat(0xdead_beef);

    // Selector 6 recovers to the GDS group, which nothing here reads.
    var words: [16]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    try testing.expect(dcb(
        &buffer,
        memory_selector_dcb,
        0,
        @intFromPtr(&destination),
        6,
        0,
        @intFromPtr(&source),
        0,
        0,
    ) != null);
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    try testing.expectEqual(@as(u32, 0xdead_beef), destination[0]);
    try testing.expectEqual(@as(u64, 1), state.copy_data_count);
    try testing.expectEqual(@as(u64, 1), state.copy_data_unsupported_count);
    try testing.expectEqual(gpu.state.CopyData.Selector.gds, state.last_copy.?.source);
}
