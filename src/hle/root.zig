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
    context_at_draw: ?u32 = null,
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

    fn draw(context: ?*anyopaque, state: *const gpu_module.State, _: gpu_module.pm4.Packet) bool {
        from(context).draws += 1;
        from(context).context_at_draw = state.readRegister(.context, probe_register);
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
    // Independent PM4 expectation: TC/TC, read policy 2, write policy 1,
    // 64-bit width, write confirmation, and ME selection.
    try testing.expectEqualSlices(u32, &.{ 0xc004_4000, 0x0211_4202, 0x2000, 1, 0x4000, 2 }, graphics[0..6]);
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
        for ([_]struct { write: *const AgcCopyData, source: u64, destination: u64 }{
            .{ .write = dcb, .source = memory_selector_dcb, .destination = memory_selector_dcb },
            .{ .write = acb, .source = memory_selector_acb, .destination = memory_selector_acb },
            // DCB bit zero selects PFP independently of the source selector.
            .{ .write = dcb, .source = 3, .destination = 10 },
            .{ .write = dcb, .source = 5, .destination = 4 },
            .{ .write = acb, .source = 1, .destination = 5 },
        }) |form| {
            var source: [2]u32 = .{ 0x1122_3344, 0x5566_7788 };
            var destination: [4]u32 = @splat(0xdead_beef);

            var words: [16]u32 = @splat(0);
            var buffer = sizedBuffer(&words);
            try testing.expect(form.write(
                &buffer,
                form.destination,
                0,
                @intFromPtr(&destination),
                form.source,
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

    // DCB selector 6 encodes PM4 source 3 (GDS), which is unsupported.
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

// ---------------------------------------------------------------------------
// Fusing shader halves
//
// A geometry or hull shader arrives as two objects and is drawn as one. Two
// exports do the joining and differ in exactly two places, so these drive both
// through the registry and compare them against each other rather than against
// a transcription of either.

const AgcFuse = fn (
    ?*anyopaque,
    ?*const anyopaque,
    ?*const anyopaque,
    ?*anyopaque,
) callconv(abi.guest) i32;

const AgcFusedSize = fn (?*anyopaque, ?*const anyopaque, ?*const anyopaque) callconv(abi.guest) i32;

/// The shader header, as the library lays it out.
const shader_bytes: usize = 0x60;
const user_data_at: usize = 0x08;
const code_at: usize = 0x10;
const sh_registers_at: usize = 0x20;
const specials_at: usize = 0x28;
const type_at: usize = 0x5a;
const sh_register_count_at: usize = 0x5c;
/// The context register array and its count, used by the occupancy query.
const cx_registers_at: usize = 0x18;
const cx_count_at: usize = 0x5b;

/// Binary types: the two halves of each pair, and what they fuse into.
const gs_front: u8 = 4;
const gs_back: u8 = 6;
const hs_front: u8 = 5;
const hs_back: u8 = 7;
const gs_fused: u8 = 2;
const hs_fused: u8 = 3;

const chksum_gs: u32 = 0x80;
const rsrc1_gs: u32 = 0x8a;
const rsrc2_gs: u32 = 0x8b;
const lo_es: u32 = 0xc8;
const chksum_hs: u32 = 0x100;
const rsrc1_hs: u32 = 0x10a;
const rsrc2_hs: u32 = 0x10b;
const lo_ls: u32 = 0x148;

const FuseRegister = extern struct { offset: u32, value: u32 };

const ShaderHeader = extern struct {
    bytes: [shader_bytes]u8 align(8) = @splat(0),

    fn address(self: *ShaderHeader) usize {
        return @intFromPtr(&self.bytes);
    }

    fn put(self: *ShaderHeader, offset: usize, value: u64) void {
        const std = @import("std");
        std.mem.writeInt(u64, self.bytes[offset..][0..8], value, .little);
    }

    fn get(self: *const ShaderHeader, offset: usize) u64 {
        const std = @import("std");
        return std.mem.readInt(u64, self.bytes[offset..][0..8], .little);
    }

    fn describe(
        self: *ShaderHeader,
        binary_type: u8,
        registers: []FuseRegister,
        specials: ?*const anyopaque,
        code: ?*const anyopaque,
    ) void {
        self.bytes[type_at] = binary_type;
        self.bytes[sh_register_count_at] = @intCast(registers.len);
        self.put(sh_registers_at, @intFromPtr(registers.ptr));
        self.put(specials_at, if (specials) |s| @intFromPtr(s) else 0);
        self.put(code_at, if (code) |c| @intFromPtr(c) else 0);
    }
};

/// VGT_SHADER_STAGES_EN sits at +0x08 of the specials array, so the wave-size
/// bit lands in the second register's value.
const Specials = extern struct {
    entries: [8]FuseRegister = @splat(.{ .offset = 0, .value = 0 }),

    fn withStages(value: u32) Specials {
        var self = Specials{};
        self.entries[1] = .{ .offset = 0, .value = value };
        return self;
    }
};

fn findFused(registers: []const FuseRegister, offset: u32) ?FuseRegister {
    for (registers) |entry| {
        if (entry.offset == offset) return entry;
    }
    return null;
}

test "both fuse exports join a geometry pair and differ only where they should" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const reallocating = try agcEntryPoint(&db, "fd5Bp5tGTgo", AgcFuse);
    const keeping = try agcEntryPoint(&db, "nApJjpKNBl4", AgcFuse);

    for ([_]struct { fuse: *const AgcFuse, recomputes: bool }{
        .{ .fuse = reallocating, .recomputes = true },
        .{ .fuse = keeping, .recomputes = false },
    }) |form| {
        var code: [16]u8 align(256) = @splat(0);
        var user_data: [8]u64 = @splat(0);

        // The front half wants more private registers; the back half wants
        // more shared registers and export components. The fused allocation
        // must cover both, even when their private/shared split differs.
        var front_registers = [_]FuseRegister{
            .{ .offset = chksum_gs, .value = 0x1111_1111 },
            .{ .offset = chksum_gs, .value = 0x2222_2222 },
            // VGPRS = 7, GS_VGPR_COMP_CNT = 2, plus float-mode bits that must
            // survive untouched.
            .{ .offset = rsrc1_gs, .value = 0x4000_5007 | (@as(u32, 2) << 29) },
            // USER_SGPR = 9 with its high bit, OC_LDS_EN, ES comp = 1,
            // and one shared block.
            .{ .offset = rsrc2_gs, .value = (9 << 1) | (1 << 27) | (1 << 18) | (1 << 28) | (1 << 16) },
        };
        var back_registers = [_]FuseRegister{
            .{ .offset = lo_es, .value = 0 },
            .{ .offset = lo_es + 1, .value = 0 },
            .{ .offset = chksum_gs, .value = 0 },
            .{ .offset = chksum_gs, .value = 0 },
            // VGPRS = 3, comp count 0, different float mode bits.
            .{ .offset = rsrc1_gs, .value = 0x0080_9003 },
            // USER_SGPR = 2, no OC_LDS, SHARED_VGPR_CNT = 4, ES comp = 3,
            // LDS_SIZE and SCRATCH_EN set so they can be shown to survive.
            .{ .offset = rsrc2_gs, .value = 1 | (2 << 1) | (3 << 16) | (0x5a << 19) | (4 << 28) },
        };

        const stages = Specials{}; // Shared VGPR allocation is a wave64 feature.
        var front = ShaderHeader{};
        var back = ShaderHeader{};
        var fused = ShaderHeader{};
        front.describe(gs_front, &front_registers, &stages, &code);
        front.put(user_data_at, @intFromPtr(&user_data));
        back.describe(gs_back, &back_registers, &stages, null);

        var scratch: [back_registers.len]FuseRegister = undefined;
        try testing.expectEqual(errno.ok, form.fuse(&fused.bytes, &front.bytes, &back.bytes, &scratch));

        // The fused object is a geometry shader built on the scratch copy, so
        // the back half's own registers are untouched and can be fused again.
        try testing.expectEqual(gs_fused, fused.bytes[type_at]);
        try testing.expectEqual(@as(u64, @intFromPtr(&scratch)), fused.get(sh_registers_at));
        try testing.expectEqual(@as(u32, 0x0080_9003), back_registers[4].value);

        // Checksums name the code that will run, which is the front half's.
        try testing.expectEqual(@as(u32, 0x1111_1111), scratch[2].value);
        try testing.expectEqual(@as(u32, 0x2222_2222), scratch[3].value);

        const rsrc1 = findFused(&scratch, rsrc1_gs).?;
        const rsrc2 = findFused(&scratch, rsrc2_gs).?;

        // Vector count and component counts take whichever half asked for more.
        try testing.expectEqual(@as(u32, 7), rsrc1.value & 0x3f);
        try testing.expectEqual(@as(u32, 2), (rsrc1.value >> 29) & 0x3);
        try testing.expectEqual(@as(u32, 3), (rsrc2.value >> 16) & 0x3);
        // The back half's unrelated RSRC1 bits are still there. Masked to the
        // span between the vector count and the component count, because those
        // two are exactly what the merge above is allowed to touch.
        try testing.expectEqual(@as(u32, 0x0080_9000), rsrc1.value & 0x1fff_ffc0);
        // User SGPR count comes from the front half; OC_LDS_EN with it.
        try testing.expectEqual(@as(u32, 9), (rsrc2.value >> 1) & 0x1f);
        try testing.expectEqual(@as(u32, 1), (rsrc2.value >> 27) & 0x1);
        try testing.expectEqual(@as(u32, 1), (rsrc2.value >> 18) & 0x1);
        // Scratch enable and LDS size belong to the back half and stay.
        try testing.expectEqual(@as(u32, 1), rsrc2.value & 0x1);
        try testing.expectEqual(@as(u32, 0x5a), (rsrc2.value >> 19) & 0xff);
        // The export program address is the front half's code.
        try testing.expectEqual(@as(u32, @truncate(@intFromPtr(&code) >> 8)), scratch[0].value);

        // And here the two exports part company.
        const shared = (rsrc2.value >> 28) & 0xf;
        if (form.recomputes) {
            // Front needs 32 + 8 = 40 registers; back needs 16 + 32 = 48.
            // Merging to 32 private registers leaves 16 shared (two blocks).
            try testing.expectEqual(@as(u32, 2), shared);
            try testing.expectEqual(@as(u64, 0), fused.get(user_data_at));
        } else {
            // No recomputation: whichever half already asked for more.
            try testing.expectEqual(@as(u32, 4), shared);
            try testing.expectEqual(@as(u64, @intFromPtr(&user_data)), fused.get(user_data_at));
        }
    }
}

test "both fuse exports join a hull pair through its own registers" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    inline for ([_]*const [nid.encoded_len:0]u8{ "fd5Bp5tGTgo", "nApJjpKNBl4" }) |id| {
        const fuse = try agcEntryPoint(&db, id, AgcFuse);

        var code: [16]u8 align(256) = @splat(0);
        var front_registers = [_]FuseRegister{
            .{ .offset = chksum_hs, .value = 0xabcd_ef01 },
            .{ .offset = chksum_hs, .value = 0x2345_6789 },
            // LS_VGPR_COMP_CNT lives at bit 28 for a hull pair, not 29.
            .{ .offset = rsrc1_hs, .value = 5 | (@as(u32, 3) << 28) },
            .{ .offset = rsrc2_hs, .value = 4 << 1 },
        };
        var back_registers = [_]FuseRegister{
            .{ .offset = lo_ls, .value = 0 },
            .{ .offset = lo_ls + 1, .value = 0 },
            .{ .offset = chksum_hs, .value = 0 },
            .{ .offset = chksum_hs, .value = 0 },
            .{ .offset = rsrc1_hs, .value = 9 },
            .{ .offset = rsrc2_hs, .value = 0 },
        };

        const stages = Specials.withStages(1 << 21);
        var front = ShaderHeader{};
        var back = ShaderHeader{};
        var fused = ShaderHeader{};
        front.describe(hs_front, &front_registers, &stages, &code);
        back.describe(hs_back, &back_registers, &stages, null);

        var scratch: [back_registers.len]FuseRegister = undefined;
        try testing.expectEqual(errno.ok, fuse(&fused.bytes, &front.bytes, &back.bytes, &scratch));

        try testing.expectEqual(hs_fused, fused.bytes[type_at]);
        // The hull checksum register, not the geometry one.
        try testing.expectEqual(@as(u32, 0xabcd_ef01), scratch[2].value);
        try testing.expectEqual(@as(u32, 0x2345_6789), scratch[3].value);

        const rsrc1 = findFused(&scratch, rsrc1_hs).?;
        try testing.expectEqual(@as(u32, 9), rsrc1.value & 0x3f);
        try testing.expectEqual(@as(u32, 3), (rsrc1.value >> 28) & 0x3);
        // Bit 29 is part of the hull component count; bit 31 is not touched.
        try testing.expectEqual(@as(u32, 0), (rsrc1.value >> 30) & 0x3);
        // The hull program address goes to LO_LS.
        try testing.expectEqual(@as(u32, @truncate(@intFromPtr(&code) >> 8)), scratch[0].value);
    }
}

test "the fused object reports the scratch it needs and works without it" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const size_of = try agcEntryPoint(&db, "dolOmWH+huQ", AgcFusedSize);
    const fuse = try agcEntryPoint(&db, "nApJjpKNBl4", AgcFuse);

    var front_registers = [_]FuseRegister{
        .{ .offset = rsrc1_gs, .value = 9 },
        .{ .offset = rsrc2_gs, .value = 0 },
    };
    var back_registers = [_]FuseRegister{
        .{ .offset = lo_es, .value = 0 },
        .{ .offset = lo_es + 1, .value = 0 },
        .{ .offset = rsrc1_gs, .value = 7 },
        .{ .offset = rsrc2_gs, .value = 0 },
    };

    var front = ShaderHeader{};
    var back = ShaderHeader{};
    var fused = ShaderHeader{};
    front.describe(gs_front, &front_registers, null, null);
    back.describe(gs_back, &back_registers, null, null);

    // One entry per back register, four-byte aligned: the scratch is a private
    // copy of the back half's array and nothing else.
    const SizeAlign = extern struct { size: u64, align_bytes: u64 };
    var reported: SizeAlign = .{ .size = 0, .align_bytes = 0 };
    try testing.expectEqual(errno.ok, size_of(&reported, &front.bytes, &back.bytes));
    try testing.expectEqual(@as(u64, back_registers.len * @sizeOf(FuseRegister)), reported.size);
    try testing.expectEqual(@as(u64, 4), reported.align_bytes);

    // Given none, the merge lands in the back half's own array, which the
    // caller then owns the consequences of.
    try testing.expectEqual(errno.ok, fuse(&fused.bytes, &front.bytes, &back.bytes, null));
    try testing.expectEqual(@as(u64, @intFromPtr(&back_registers)), fused.get(sh_registers_at));
    try testing.expectEqual(@as(u32, 9), back_registers[2].value & 0x3f);

    // Given scratch of the reported size, the back half is left alone.
    back_registers[2].value = 7;
    const before = back_registers;
    var scratch: [back_registers.len]FuseRegister = undefined;
    try testing.expectEqual(errno.ok, fuse(&fused.bytes, &front.bytes, &back.bytes, &scratch));
    try testing.expectEqual(@as(u64, @intFromPtr(&scratch)), fused.get(sh_registers_at));
    try testing.expectEqual(@as(u32, 7), back_registers[2].value);
    try testing.expectEqual(@as(u32, 9), scratch[2].value & 0x3f);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&back_registers));
}

test "halves that do not belong together are refused by both exports" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const size_of = try agcEntryPoint(&db, "dolOmWH+huQ", AgcFusedSize);
    const invalid_halves: i32 = @bitCast(@as(u32, 0x8a6c_0008));

    inline for ([_]*const [nid.encoded_len:0]u8{ "fd5Bp5tGTgo", "nApJjpKNBl4" }) |id| {
        const fuse = try agcEntryPoint(&db, id, AgcFuse);

        var registers = [_]FuseRegister{.{ .offset = rsrc1_gs, .value = 0 }};
        var front = ShaderHeader{};
        var back = ShaderHeader{};
        var fused = ShaderHeader{};

        // A geometry front with a hull back, and the two crossings of that.
        const mismatches = [_]struct { front: u8, back: u8 }{
            .{ .front = gs_front, .back = hs_back },
            .{ .front = hs_front, .back = gs_back },
            .{ .front = gs_back, .back = gs_back },
            .{ .front = gs_front, .back = gs_front },
        };
        for (mismatches) |pair| {
            front.describe(pair.front, &registers, null, null);
            back.describe(pair.back, &registers, null, null);
            try testing.expectEqual(invalid_halves, fuse(&fused.bytes, &front.bytes, &back.bytes, null));
            try testing.expectEqual(invalid_halves, size_of(&fused.bytes, &front.bytes, &back.bytes));
        }

        // A matched pair compiled for different wave sizes is refused too: the
        // stage bit says wave32 on one half and wave64 on the other, and the
        // registers below it would mean different things.
        const wave32 = Specials.withStages(1 << 22);
        const wave64 = Specials{};
        front.describe(gs_front, &registers, &wave32, null);
        back.describe(gs_back, &registers, &wave64, null);
        try testing.expectEqual(invalid_halves, fuse(&fused.bytes, &front.bytes, &back.bytes, null));

        // The same pair agreeing on the wave size fuses.
        back.describe(gs_back, &registers, &wave32, null);
        try testing.expectEqual(errno.ok, fuse(&fused.bytes, &front.bytes, &back.bytes, null));

        // A hull pair is checked on its own bit, so the geometry bit differing
        // does not refuse it.
        const hull_stages = Specials.withStages(1 << 21);
        const hull_other = Specials.withStages((1 << 21) | (1 << 22));
        front.describe(hs_front, &registers, &hull_stages, null);
        back.describe(hs_back, &registers, &hull_other, null);
        try testing.expectEqual(errno.ok, fuse(&fused.bytes, &front.bytes, &back.bytes, null));

        try testing.expectEqual(errno.KernelError.einval.raw(), fuse(null, &front.bytes, &back.bytes, null));
        try testing.expectEqual(errno.KernelError.einval.raw(), fuse(&fused.bytes, null, &back.bytes, null));
        try testing.expectEqual(errno.KernelError.einval.raw(), fuse(&fused.bytes, &front.bytes, null, null));
    }
}

test "fused shared VGPR allocation covers each half after private registers merge" {
    const std = @import("std");
    const testing = std.testing;
    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const fuse = try agcEntryPoint(&db, "fd5Bp5tGTgo", AgcFuse);

    const Case = struct { front_private: u32, front_shared: u32, back_private: u32, back_shared: u32, expected_shared: u32 };
    // Private counts are decoded register counts, not the encoded RSRC1 field.
    // Include equal totals, private coverage, an eight-register rounding edge,
    // and a near-limit allocation. Expectations follow allocation sizes rather
    // than the implementation's arithmetic.
    const cases = [_]Case{
        .{ .front_private = 32, .front_shared = 8, .back_private = 32, .back_shared = 8, .expected_shared = 8 },
        .{ .front_private = 32, .front_shared = 8, .back_private = 16, .back_shared = 32, .expected_shared = 16 },
        .{ .front_private = 4, .front_shared = 8, .back_private = 8, .back_shared = 0, .expected_shared = 8 },
        .{ .front_private = 16, .front_shared = 8, .back_private = 24, .back_shared = 0, .expected_shared = 0 },
        .{ .front_private = 128, .front_shared = 120, .back_private = 136, .back_shared = 0, .expected_shared = 112 },
    };
    for ([_]bool{ false, true }) |hull| {
        for (cases) |item| {
            // Swapping the two resource demands must not change the allocation.
            for ([_]bool{ false, true }) |swap| {
                const r1: u32 = if (hull) rsrc1_hs else rsrc1_gs;
                const r2: u32 = if (hull) rsrc2_hs else rsrc2_gs;
                var front_regs = [_]FuseRegister{
                    .{ .offset = r1, .value = (if (swap) item.back_private else item.front_private) / 4 - 1 },
                    .{ .offset = r2, .value = ((if (swap) item.back_shared else item.front_shared) / 8) << 28 },
                };
                var back_regs = [_]FuseRegister{
                    .{ .offset = r1, .value = (if (swap) item.front_private else item.back_private) / 4 - 1 },
                    .{ .offset = r2, .value = ((if (swap) item.front_shared else item.back_shared) / 8) << 28 },
                };
                const stages = Specials{}; // Wave64, where shared VGPRs are available.
                var front = ShaderHeader{};
                var back = ShaderHeader{};
                var fused = ShaderHeader{};
                front.describe(if (hull) hs_front else gs_front, &front_regs, &stages, null);
                back.describe(if (hull) hs_back else gs_back, &back_regs, &stages, null);
                var scratch: [2]FuseRegister = undefined;
                try testing.expectEqual(errno.ok, fuse(&fused.bytes, &front.bytes, &back.bytes, &scratch));
                const private = ((scratch[0].value & 0x3f) + 1) * 4;
                const shared = (scratch[1].value >> 28) * 8;
                try testing.expectEqual(item.expected_shared, shared);
                try testing.expectEqual(@max(item.front_private, item.back_private), private);
                try testing.expect(private + shared >= item.front_private + item.front_shared);
                try testing.expect(private + shared >= item.back_private + item.back_shared);
                try testing.expect(private + shared <= 256);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Context state
//
// A title brackets a pass with save and restore so the registers it sets do
// not leak into what follows. The constructor writes a packet the command
// processor understands, so these build with the registered constructor and
// run the result -- a writer on its own would prove nothing.

const AgcContextStateOp = fn (
    ?*libs.agc.CommandBuffer,
    u32,
    u64,
    u64,
    u64,
    u64,
) callconv(abi.guest) ?[*]u32;

const context_clear: u32 = 0;
const context_push: u32 = 1;
const context_pop: u32 = 2;
const context_push_clear: u32 = 3;

/// A context register a draw would read, chosen away from the ones the other
/// constructors in these tests write.
const probe_register: u32 = 0x318;

fn setContextRegister(buffer: *libs.agc.CommandBuffer, value: u32) void {
    const gpu_module = @import("gpu");
    const words = agc_reserve(buffer, 3);
    words[0] = pm4Command(gpu_module.pm4.set_context_reg, 2);
    words[1] = probe_register;
    words[2] = value;
}

fn agc_reserve(buffer: *libs.agc.CommandBuffer, count: u32) [*]u32 {
    return libs.agc.reserveDwords(buffer, count).?;
}

test "context state saves, survives changes, and restores" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);
    const get_size = try agcEntryPoint(&db, "H6vHS5cidSA", AgcGetSize);

    var words: [128]u32 = @splat(0);
    var buffer = sizedBuffer(&words);

    // Set a register, save it, change it, restore it, then draw so the state
    // the draw sees is the one that was restored.
    setContextRegister(&buffer, 0x1111_1111);
    try testing.expect(context_op(&buffer, context_push, 0, 0, 0, 0) != null);
    setContextRegister(&buffer, 0x2222_2222);
    try testing.expect(context_op(&buffer, context_pop, 0, 0, 0, 0) != null);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);
    _ = draw(&buffer, 3, 0, 0, 0, 0).?;

    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    try testing.expectEqual(@as(u32, 1), probe.draws);
    try testing.expectEqual(@as(?u32, 0x1111_1111), state.readRegister(.context, probe_register));
    try testing.expectEqual(@as(?u32, 0x1111_1111), probe.context_at_draw);
    try testing.expectEqual(@as(u8, 0), state.context_depth);
    try testing.expectEqual(@as(u64, 1), state.context_state_push_count);
    try testing.expectEqual(@as(u64, 1), state.context_state_pop_count);

    // Each operation occupies the span its size query promised.
    try testing.expectEqual(@as(u32, 5 * @sizeOf(u32)), get_size(context_clear, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 27 * @sizeOf(u32)), get_size(context_push, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 27 * @sizeOf(u32)), get_size(context_pop, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 32 * @sizeOf(u32)), get_size(context_push_clear, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0), get_size(4, 0, 0, 0, 0, 0));
}

test "each context operation writes exactly the span it reports" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);
    const get_size = try agcEntryPoint(&db, "H6vHS5cidSA", AgcGetSize);

    for ([_]u32{ context_clear, context_push, context_pop, context_push_clear }) |operation| {
        const announced = get_size(operation, 0, 0, 0, 0, 0);
        const announced_words = announced / @sizeOf(u32);

        var storage: [64]u32 = @splat(guard_word);
        var buffer = sizedBuffer(storage[0..announced_words]);
        try testing.expect(context_op(&buffer, operation, 0, 0, 0, 0) != null);
        try testing.expectEqual(
            @as(usize, announced),
            @intFromPtr(buffer.cursor_up.?) - @intFromPtr(storage[0..].ptr),
        );
        for (storage[announced_words..]) |word| try testing.expectEqual(guard_word, word);

        // The span is a walkable run of packets, and the first one carries the
        // operation where the command processor looks for it.
        var walker = gpu.pm4.Walker.init(storage[0..announced_words]);
        const first = (try walker.next()).?;
        try testing.expectEqual(gpu.pm4.nop, first.opcode);
        try testing.expectEqual(@as(?u6, gpu.pm4.custom.context_state), gpu.pm4.customCode(first));
        try testing.expectEqual(operation, first.body[0]);
        var seen: usize = first.wordCount();
        while (try walker.next()) |packet| seen += packet.wordCount();
        try testing.expectEqual(@as(usize, announced_words), seen);

        // One word short is refused, and refusing writes nothing at all --
        // half an operation would leave a packet the processor walks into.
        var tight: [64]u32 = @splat(guard_word);
        var short = sizedBuffer(tight[0 .. announced_words - 1]);
        try testing.expect(context_op(&short, operation, 0, 0, 0, 0) == null);
        for (tight) |word| try testing.expectEqual(guard_word, word);
    }
}

test "context saves nest, and the stack has a bottom and a top" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);

    var words: [512]u32 = @splat(0);
    var buffer = sizedBuffer(&words);

    // Four nested saves, each around a different value, then four restores.
    const depth = gpu.state.context_state_depth;
    for (0..depth) |level| {
        setContextRegister(&buffer, @intCast(0x100 + level));
        try testing.expect(context_op(&buffer, context_push, 0, 0, 0, 0) != null);
    }
    setContextRegister(&buffer, 0x999);

    const used_push = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used_push]);
    try testing.expectEqual(@as(u8, depth), state.context_depth);
    try testing.expectEqual(@as(?u32, 0x999), state.readRegister(.context, probe_register));

    // Restoring unwinds innermost first.
    var level = depth;
    while (level > 0) {
        level -= 1;
        var pop_words: [64]u32 = @splat(0);
        var pop_buffer = sizedBuffer(&pop_words);
        try testing.expect(context_op(&pop_buffer, context_pop, 0, 0, 0, 0) != null);
        const used = (@intFromPtr(pop_buffer.cursor_up.?) - @intFromPtr(pop_words[0..].ptr)) / @sizeOf(u32);
        _ = try runPredicated(&probe, &state, pop_words[0..used]);
        try testing.expectEqual(@as(u8, @intCast(level)), state.context_depth);
        try testing.expectEqual(@as(?u32, @intCast(0x100 + level)), state.readRegister(.context, probe_register));
    }

    // A pop with nothing saved is refused rather than restoring a register
    // file that belongs to no pass.
    const before = state.readRegister(.context, probe_register);
    var empty_words: [64]u32 = @splat(0);
    var empty_buffer = sizedBuffer(&empty_words);
    try testing.expect(context_op(&empty_buffer, context_pop, 0, 0, 0, 0) != null);
    const empty_used = (@intFromPtr(empty_buffer.cursor_up.?) - @intFromPtr(empty_words[0..].ptr)) / @sizeOf(u32);
    try testing.expectError(error.ContextStateStackFault, runPredicated(&probe, &state, empty_words[0..empty_used]));
    try testing.expectEqual(@as(u8, 0), state.context_depth);
    try testing.expectEqual(before, state.readRegister(.context, probe_register));
    try testing.expectEqual(@as(u64, 1), state.context_state_refused_count);

    // And one push past the top is refused the same way.
    for (0..depth + 1) |index| {
        var push_words: [64]u32 = @splat(0);
        var push_buffer = sizedBuffer(&push_words);
        try testing.expect(context_op(&push_buffer, context_push, 0, 0, 0, 0) != null);
        const used = (@intFromPtr(push_buffer.cursor_up.?) - @intFromPtr(push_words[0..].ptr)) / @sizeOf(u32);
        if (index == depth) {
            try testing.expectError(error.ContextStateStackFault, runPredicated(&probe, &state, push_words[0..used]));
        } else {
            _ = try runPredicated(&probe, &state, push_words[0..used]);
        }
    }
    try testing.expectEqual(@as(u8, depth), state.context_depth);
    try testing.expectEqual(@as(u64, 2), state.context_state_refused_count);
}

test "clearing context leaves the predicate and the pending wait alone" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);

    var predicate: [4]u64 align(16) = @splat(1);

    var words: [256]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    setContextRegister(&buffer, 0x5555_5555);
    // Establish a predicate, then push-and-clear: the context goes, the
    // predicate stays, because a title clears context between passes and does
    // not expect the guard it just set up to be forgotten.
    try buildPredication(&db, &buffer, 0, 3, 0, @intFromPtr(&predicate));
    try testing.expect(context_op(&buffer, context_push_clear, 0, 0, 0, 0) != null);

    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var probe = PredicationProbe{};
    var state = gpu.State{};
    _ = try runPredicated(&probe, &state, words[0..used]);

    // Context was saved and then dropped.
    try testing.expectEqual(@as(u8, 1), state.context_depth);
    try testing.expectEqual(@as(?u32, null), state.readRegister(.context, probe_register));
    try testing.expectEqual(@as(u64, 1), state.context_state_clear_count);

    // The predicate and what it was read from are untouched.
    try testing.expect(state.predicate_skip);
    try testing.expectEqual(@as(u64, 1), state.predication_enable_count);
    try testing.expect(state.last_predication != null);

    // And restoring brings the register back without disturbing the predicate.
    var pop_words: [64]u32 = @splat(0);
    var pop_buffer = sizedBuffer(&pop_words);
    try testing.expect(context_op(&pop_buffer, context_pop, 0, 0, 0, 0) != null);
    const pop_used = (@intFromPtr(pop_buffer.cursor_up.?) - @intFromPtr(pop_words[0..].ptr)) / @sizeOf(u32);
    _ = try runPredicated(&probe, &state, pop_words[0..pop_used]);
    try testing.expectEqual(@as(?u32, 0x5555_5555), state.readRegister(.context, probe_register));
    try testing.expect(state.predicate_skip);
}

test "a saved context belongs to its own queue" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);

    // Two queues, each with its own register file and its own saved copies.
    var graphics = gpu.State{};
    var compute = gpu.State{};
    var probe = PredicationProbe{};

    var words: [256]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    setContextRegister(&buffer, 0xaaaa_aaaa);
    try testing.expect(context_op(&buffer, context_push, 0, 0, 0, 0) != null);
    setContextRegister(&buffer, 0xbbbb_bbbb);
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    _ = try runPredicated(&probe, &graphics, words[0..used]);
    try testing.expectEqual(@as(u8, 1), graphics.context_depth);
    try testing.expectEqual(@as(u8, 0), compute.context_depth);
    try testing.expectEqual(@as(?u32, null), compute.readRegister(.context, probe_register));

    // A pop on the other queue finds nothing saved: the stacks do not meet.
    var pop_words: [64]u32 = @splat(0);
    var pop_buffer = sizedBuffer(&pop_words);
    try testing.expect(context_op(&pop_buffer, context_pop, 0, 0, 0, 0) != null);
    const pop_used = (@intFromPtr(pop_buffer.cursor_up.?) - @intFromPtr(pop_words[0..].ptr)) / @sizeOf(u32);
    try testing.expectError(error.ContextStateStackFault, runPredicated(&probe, &compute, pop_words[0..pop_used]));
    try testing.expectEqual(@as(u64, 1), compute.context_state_refused_count);
    try testing.expectEqual(@as(u64, 0), graphics.context_state_refused_count);
    try testing.expectEqual(@as(u8, 1), graphics.context_depth);
}

test "a save survives the wait that splits its command buffer" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);

    // Driven through the queue scheduler rather than a bare executor, because
    // parking on a wait and continuing afterwards is the scheduler's job: a
    // bare executor stops at the wait and never comes back.
    var label: [1]u32 = @splat(0);
    const label_address = @intFromPtr(&label);

    var words: [256]u32 = @splat(0);
    var buffer = sizedBuffer(&words);
    setContextRegister(&buffer, 0x7777_7777);
    try testing.expect(context_op(&buffer, context_push, 0, 0, 0, 0) != null);
    setContextRegister(&buffer, 0x8888_8888);

    const wait = agc_reserve(&buffer, 7);
    wait[0] = pm4Command(gpu.pm4.wait_reg_mem, 6);
    wait[1] = 0x13; // memory space, compare equal
    wait[2] = @truncate(label_address);
    wait[3] = @truncate(label_address >> 32);
    wait[4] = 1;
    wait[5] = 0xffff_ffff;
    wait[6] = 0x10;

    try testing.expect(context_op(&buffer, context_pop, 0, 0, 0, 0) != null);
    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    var probe = PredicationProbe{};
    var scheduler = gpu.QueueScheduler.init(testing.allocator, probe.backend());
    defer scheduler.deinit();

    // The stream parks on the wait, with the save already made.
    _ = try scheduler.submit(.graphics, words[0..used]);
    try testing.expect(scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(u8, 1), scheduler.state(.graphics).context_depth);
    try testing.expectEqual(
        @as(?u32, 0x8888_8888),
        scheduler.state(.graphics).readRegister(.context, probe_register),
    );

    // The label arrives and the rest of the buffer runs. The restore on the
    // far side of the wait finds the copy saved before it.
    label[0] = 1;
    _ = try scheduler.pump();
    try testing.expect(!scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(u8, 0), scheduler.state(.graphics).context_depth);
    try testing.expectEqual(
        @as(?u32, 0x7777_7777),
        scheduler.state(.graphics).readRegister(.context, probe_register),
    );
    try testing.expectEqual(@as(u64, 1), scheduler.state(.graphics).context_state_push_count);
    try testing.expectEqual(@as(u64, 1), scheduler.state(.graphics).context_state_pop_count);
}

test "context stack faults stop the submission before an outer pop or draw" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;
    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);
    const context_op = try agcEntryPoint(&db, "qj7QZpgr9Uw", AgcContextStateOp);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    for ([_]u32{ context_push, context_push_clear, context_pop }) |operation| {
        var probe = PredicationProbe{};
        var scheduler = gpu.QueueScheduler.init(testing.allocator, probe.backend());
        defer scheduler.deinit();
        const state = scheduler.state(.graphics);
        if (operation != context_pop) {
            for (0..gpu.state.context_state_depth) |level| {
                try state.writeRegister(.context, probe_register, @intCast(level));
                try testing.expect(state.applyContextStateOperation(.push));
            }
        }
        try state.writeRegister(.context, probe_register, 0xbeef);
        const depth_before = state.context_depth;
        var words: [80]u32 = @splat(0);
        var buffer = sizedBuffer(&words);
        _ = context_op(&buffer, operation, 0, 0, 0, 0).?;
        // Continuing after a refused push would pop the outer frame here.
        _ = context_op(&buffer, context_pop, 0, 0, 0, 0).?;
        _ = draw(&buffer, 3, 0, 0, 0, 0).?;
        const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(&words)) / @sizeOf(u32);
        try testing.expectError(error.ContextStateStackFault, scheduler.submit(.graphics, words[0..used]));
        try testing.expectEqual(depth_before, state.context_depth);
        try testing.expectEqual(@as(?u32, 0xbeef), state.readRegister(.context, probe_register));
        try testing.expectEqual(@as(u32, 0), probe.draws);
        try testing.expectEqual(@as(u64, 1), state.context_state_refused_count);
        try testing.expectEqual(@as(usize, 0), scheduler.pendingCount(.graphics));
    }
}

// ---------------------------------------------------------------------------
// Primitive state
//
// The state a draw runs under is two small register arrays the title fills
// once and re-points at a new topology as it goes. These check the arrays and
// then check that what ends up in front of a draw is what the arrays said.

const AgcUpdatePrim = fn (
    ?[*]PrimRegister,
    ?[*]PrimRegister,
    u32,
) callconv(abi.guest) i32;

const PrimRegister = extern struct { offset: u32, value: u32 };

/// VGT_SHADER_STAGES_EN is context 0x2d5; HS_EN is bit 2 and GS_EN is bit 5.
const stages_register: u32 = 0x2d5;
const hull_stage_enabled: u32 = 1 << 2;
const geometry_stage_enabled: u32 = 1 << 5;
/// VGT_GS_OUT_PRIM_TYPE, as `sceAgcCreatePrimState` leaves it.
const gs_out_register: u32 = 0x29b;
/// VGT_PRIMITIVE_TYPE.
const primitive_register: u32 = 0x242;

/// Context and uconfig arrays with recognisable bits around the fields that
/// the update is allowed to move.
fn primContext(stages: u32) [2]PrimRegister {
    return .{
        .{ .offset = stages_register, .value = stages },
        .{ .offset = gs_out_register, .value = 0xabcd_ef00 | 2 },
    };
}

fn primUconfig(primitive_type: u32) [3]PrimRegister {
    return .{
        .{ .offset = 0x2ff, .value = 0x1111_1111 },
        .{ .offset = 0x2fe, .value = 0x2222_2222 },
        .{ .offset = primitive_register, .value = 0x7654_3200 | primitive_type },
    };
}

test "updating primitive state rewrites both topologies and nothing else" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const update = try agcEntryPoint(&db, "Y3ymLfZ1384", AgcUpdatePrim);

    // Input topology and the geometry output it implies. The two columns are
    // deliberately different numbers.
    const cases = [_]struct { input: u32, gs_out: u32 }{
        .{ .input = 1, .gs_out = 0 }, // points
        .{ .input = 2, .gs_out = 1 }, // line list
        .{ .input = 3, .gs_out = 1 }, // line strip
        .{ .input = 18, .gs_out = 1 }, // line loop
        .{ .input = 10, .gs_out = 1 }, // line list with adjacency
        .{ .input = 4, .gs_out = 2 }, // triangle list
        .{ .input = 6, .gs_out = 2 }, // triangle strip
        .{ .input = 12, .gs_out = 2 }, // triangle list with adjacency
        .{ .input = 9, .gs_out = 2 }, // patches
        .{ .input = 7, .gs_out = 3 }, // rectangle list
        .{ .input = 17, .gs_out = 4 }, // legacy rectangle list
        .{ .input = 21, .gs_out = 2 }, // polygon
    };

    for (cases) |case| {
        var cx = primContext(0);
        var uc = primUconfig(4);
        try testing.expectEqual(errno.ok, update(&cx, &uc, case.input));

        try testing.expectEqual(case.gs_out, cx[1].value & 0x7);
        try testing.expectEqual(case.input, uc[2].value & 0x1f);

        // Offsets and every bit outside the two fields are untouched.
        try testing.expectEqual(stages_register, cx[0].offset);
        try testing.expectEqual(gs_out_register, cx[1].offset);
        try testing.expectEqual(primitive_register, uc[2].offset);
        try testing.expectEqual(@as(u32, 0), cx[0].value);
        try testing.expectEqual(@as(u32, 0xabcd_ef00), cx[1].value & ~@as(u32, 0x7));
        try testing.expectEqual(@as(u32, 0x7654_3200), uc[2].value & ~@as(u32, 0x1f));
        try testing.expectEqual(@as(u32, 0x1111_1111), uc[0].value);
        try testing.expectEqual(@as(u32, 0x2222_2222), uc[1].value);
    }
}

test "a stage that owns the output topology keeps it" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const update = try agcEntryPoint(&db, "Y3ymLfZ1384", AgcUpdatePrim);

    // A geometry shader emits what it was compiled to emit, and a hull shader
    // hands the tessellator's output on. In both cases the input topology says
    // nothing about what leaves the pipeline, so the field must not move.
    for ([_]u32{
        geometry_stage_enabled,
        hull_stage_enabled,
        geometry_stage_enabled | hull_stage_enabled,
    }) |stages| {
        var cx = primContext(stages);
        var uc = primUconfig(4);
        const before = cx[1].value;

        try testing.expectEqual(errno.ok, update(&cx, &uc, 1));
        try testing.expectEqual(before, cx[1].value);
        // The input topology still changes: that is what the draw is issued as.
        try testing.expectEqual(@as(u32, 1), uc[2].value & 0x1f);
    }

    // With other stage bits set but neither of those two, the field moves.
    var cx = primContext(0x0220_2000 | (1 << 3));
    var uc = primUconfig(4);
    try testing.expectEqual(errno.ok, update(&cx, &uc, 1));
    try testing.expectEqual(@as(u32, 0), cx[1].value & 0x7);
}

test "primitive state refuses arguments it cannot honour" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const update = try agcEntryPoint(&db, "Y3ymLfZ1384", AgcUpdatePrim);

    // Either array on its own is enough, and neither is required.
    var cx = primContext(0);
    var uc = primUconfig(4);
    try testing.expectEqual(errno.ok, update(&cx, null, 1));
    try testing.expectEqual(@as(u32, 0), cx[1].value & 0x7);
    try testing.expectEqual(errno.ok, update(null, &uc, 2));
    try testing.expectEqual(@as(u32, 2), uc[2].value & 0x1f);
    try testing.expectEqual(errno.ok, update(null, null, 4));

    // The field is five bits wide, so an unnamed topology would alias onto one
    // the title did not ask for. It is refused, and nothing is written.
    for ([_]u32{ 8, 14, 15, 16, 22, 32, 0xffff_ffff }) |unknown| {
        var guard_cx = primContext(0);
        var guard_uc = primUconfig(4);
        const cx_before = guard_cx[1].value;
        const uc_before = guard_uc[2].value;
        try testing.expectEqual(errno.KernelError.einval.raw(), update(&guard_cx, &guard_uc, unknown));
        try testing.expectEqual(cx_before, guard_cx[1].value);
        try testing.expectEqual(uc_before, guard_uc[2].value);
    }

    // Every named topology is accepted.
    for ([_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 17, 18, 19, 20, 21 }) |known| {
        var ok_cx = primContext(0);
        var ok_uc = primUconfig(4);
        try testing.expectEqual(errno.ok, update(&ok_cx, &ok_uc, known));
    }
}

test "a bad second array leaves the first one alone" {
    const std = @import("std");
    const guest_memory = @import("memory");
    const kernel_memory = libs.kernel_memory;
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const update = try agcEntryPoint(&db, "Y3ymLfZ1384", AgcUpdatePrim);
    const efault = errno.KernelError.efault.raw();

    // A real address space, because without one every pointer is readable and
    // the check under test never fires. One mapped page, and arrays placed
    // against its far edge so the second one runs off the end.
    var address_space = try guest_memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        16 * kernel_memory.page_size,
    );
    defer address_space.deinit();
    kernel_memory.init(testing.allocator);
    defer kernel_memory.deinit();
    kernel_memory.attachAddressSpace(&address_space);
    defer kernel_memory.attachAddressSpace(null);

    const page = kernel_memory.page_size;
    const base = guest_memory.user.start;
    try address_space.mapFixed(base, page, .{ .read = true, .write = true }, .direct_memory, 0);

    const entry_size = @sizeOf(PrimRegister);

    // The context array sits comfortably inside the page.
    const cx: [*]PrimRegister = @ptrFromInt(base);
    cx[0] = .{ .offset = stages_register, .value = 0 };
    cx[1] = .{ .offset = gs_out_register, .value = 0xabcd_ef00 | 2 };
    const cx_before = cx[1].value;

    // The uconfig array starts one entry short of the end, so its third entry
    // is past the mapping: readable memory that is not long enough.
    const truncated: [*]PrimRegister = @ptrFromInt(base + page - entry_size);
    try testing.expectEqual(efault, update(cx, truncated, 1));
    try testing.expectEqual(cx_before, cx[1].value);

    // The other way round: a truncated context array must not let the uconfig
    // one be written either.
    const uc: [*]PrimRegister = @ptrFromInt(base + 0x100);
    uc[0] = .{ .offset = 0x2ff, .value = 0x1111_1111 };
    uc[1] = .{ .offset = 0x2fe, .value = 0x2222_2222 };
    uc[2] = .{ .offset = primitive_register, .value = 0x7654_3200 | 4 };
    const uc_before = uc[2].value;
    try testing.expectEqual(efault, update(truncated, uc, 1));
    try testing.expectEqual(uc_before, uc[2].value);

    // Wholly unmapped memory is refused the same way.
    const unmapped: [*]PrimRegister = @ptrFromInt(base + 8 * page);
    try testing.expectEqual(efault, update(cx, unmapped, 1));
    try testing.expectEqual(cx_before, cx[1].value);

    // And with both arrays whole, the same call goes through.
    try testing.expectEqual(errno.ok, update(cx, uc, 1));
    try testing.expectEqual(@as(u32, 0), cx[1].value & 0x7);
    try testing.expectEqual(@as(u32, 1), uc[2].value & 0x1f);
}

/// Records the state each draw was issued under.
const TopologyProbe = struct {
    const gpu_module = @import("gpu");

    seen: [8]u32 = @splat(0),
    count: usize = 0,

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
        _: gpu_module.pm4.Packet,
    ) bool {
        const self: *TopologyProbe = @ptrCast(@alignCast(context.?));
        if (self.count < self.seen.len) {
            // Exactly what the renderer reads when it picks a pipeline.
            self.seen[self.count] = state.readRegister(.uconfig, primitive_register) orelse 0xffff;
            self.count += 1;
        }
        return true;
    }

    const vtable = gpu_module.DcbBackend.VTable{ .read = read, .write = write, .draw = draw };

    fn backend(self: *TopologyProbe) gpu_module.DcbBackend {
        return .{ .context = self, .vtable = &vtable };
    }
};

test "each draw runs under the topology set before it" {
    const std = @import("std");
    const gpu = @import("gpu");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const update = try agcEntryPoint(&db, "Y3ymLfZ1384", AgcUpdatePrim);
    const set_uc_indirect = try agcEntryPoint(&db, "hvUfkUIQcOE", AgcWrite);
    const draw = try agcEntryPoint(&db, "Yw0jKSqop+E", AgcWrite);

    // The arrays the title keeps, written into the buffer by reference: the
    // command carries their address, so the values the draw sees are the ones
    // left in them at execution time. Two copies, because both draws are in
    // one stream and the second update must not reach back into the first.
    var first_uc = primUconfig(4);
    var second_uc = primUconfig(4);
    var cx = primContext(0);

    var words: [64]u32 = @splat(0);
    var buffer = sizedBuffer(&words);

    // Point list, draw; then rectangle list, draw.
    try testing.expectEqual(errno.ok, update(&cx, &first_uc, 1));
    _ = set_uc_indirect(&buffer, @intFromPtr(&first_uc), first_uc.len, 0, 0, 0).?;
    _ = draw(&buffer, 3, 0, 0, 0, 0).?;

    try testing.expectEqual(errno.ok, update(&cx, &second_uc, 7));
    _ = set_uc_indirect(&buffer, @intFromPtr(&second_uc), second_uc.len, 0, 0, 0).?;
    _ = draw(&buffer, 4, 0, 0, 0, 0).?;

    const used = (@intFromPtr(buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);

    var probe = TopologyProbe{};
    var state = gpu.State{};
    var runner = gpu.DcbExecutor{
        .state = &state,
        .backend = probe.backend(),
        .allocator = testing.allocator,
    };
    _ = try runner.execute(words[0..used]);

    // Two draws, each under its own topology, read from the register file the
    // way the renderer reads it.
    try testing.expectEqual(@as(usize, 2), probe.count);
    try testing.expectEqual(@as(u32, 0x7654_3200 | 1), probe.seen[0]);
    try testing.expectEqual(@as(u32, 0x7654_3200 | 7), probe.seen[1]);

    // And the state left behind is the second one, low five bits being what
    // the renderer turns into a host topology.
    try testing.expectEqual(
        @as(?u32, 0x7654_3200 | 7),
        state.readRegister(.uconfig, primitive_register),
    );
}

// ---------------------------------------------------------------------------
// GS oversubscription
//
// The call reports how far a geometry shader may run past its guaranteed
// occupancy, as two registers. These build a shader whose occupancy is known
// by construction and check the answer, the bits around it, and what happens
// when the arguments are not what the call can work with.

const AgcGetGsOversubscription = fn (
    ?[*]PrimRegister,
    ?*const anyopaque,
    u32,
    f32,
) callconv(abi.guest) i32;

const uc_parameter_oversubscription: u32 = 0x260;
const spi_shader_pgm_rsrc4_gs: u32 = 0x81;
const full_pc_oversubscription: u32 = 0x7ff;
const full_sh_oversubscription: u32 = 0x007f_0000;
const gs_wave32_bit: u32 = 0x0040_0000;

/// The context registers the occupancy is read from.
const GsShader = struct {
    header: [0x60]u8 align(8) = @splat(0),
    cx: [5]PrimRegister = undefined,
    specials: [8]PrimRegister = @splat(.{ .offset = 0, .value = 0 }),


    /// A shader with one vertex-attribute slot, one export, and the given
    /// per-subgroup output. Wave32 is selected through the stage bit, which is
    /// the same bit the occupancy calculation halves the wave count on.
    fn init(self: *GsShader, output_per_subgroup: u32, wave32: bool) void {
        const std = @import("std");
        self.cx = .{
            .{ .offset = 0x291, .value = (4 << 11) }, // VGT_GS_ONCHIP_CNTL
            .{ .offset = 0x2d3, .value = 8 }, // GE_NGG_SUBGRP_CNTL
            .{ .offset = 0x1b1, .value = 0 }, // SPI_VS_OUT_CONFIG: one slot
            .{ .offset = 0x207, .value = 0 }, // PA_CL_VS_OUT_CNTL: one export
            .{ .offset = 0x1ff, .value = output_per_subgroup }, // GE_MAX_OUTPUT
        };
        self.specials[1] = .{
            .offset = 0,
            .value = if (wave32) gs_wave32_bit else 0,
        };
        self.header = @splat(0);
        self.header[type_at] = 2; // geometry
        self.header[cx_count_at] = self.cx.len;
        std.mem.writeInt(u64, self.header[cx_registers_at..][0..8], @intFromPtr(&self.cx), .little);
        std.mem.writeInt(u64, self.header[specials_at..][0..8], @intFromPtr(&self.specials), .little);
    }

    fn pointer(self: *GsShader) *const anyopaque {
        return @ptrCast(&self.header);
    }
};

/// Three entries, so the third can prove nothing past the pair is touched.
fn oversubscriptionOut() [3]PrimRegister {
    return @splat(.{ .offset = 0xdead, .value = 0xbeef_beef });
}

test "oversubscription answers the two registers and nothing beyond them" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);

    var shader = GsShader{};
    shader.init(64, true);

    var out = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&out, shader.pointer(), 0x4000, 0.5));

    // Both entries name their register, and the guard entry past them is as it
    // was left.
    try testing.expectEqual(uc_parameter_oversubscription, out[0].offset);
    try testing.expectEqual(spi_shader_pgm_rsrc4_gs, out[1].offset);
    try testing.expectEqual(@as(u32, 0xdead), out[2].offset);
    try testing.expectEqual(@as(u32, 0xbeef_beef), out[2].value);

    // Only the two oversubscription fields carry anything.
    try testing.expectEqual(@as(u32, 0), out[0].value & ~full_pc_oversubscription);
    try testing.expectEqual(@as(u32, 0), out[1].value & ~full_sh_oversubscription);
}

test "a budget of none or all does not need the shader" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);

    // No budget: both fields clear, and the shader is never looked at, so a
    // null one is not an error.
    var none = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&none, null, 0, 1.0));
    try testing.expectEqual(@as(u32, 0), none[0].value);
    try testing.expectEqual(@as(u32, 0), none[1].value);
    try testing.expectEqual(uc_parameter_oversubscription, none[0].offset);
    try testing.expectEqual(spi_shader_pgm_rsrc4_gs, none[1].offset);

    // Everything: both fields full, again without a shader.
    var all = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&all, null, std.math.maxInt(u32), 0.0));
    try testing.expectEqual(full_pc_oversubscription, all[0].value);
    try testing.expectEqual(full_sh_oversubscription, all[1].value);

    // The guard entry survives both.
    try testing.expectEqual(@as(u32, 0xbeef_beef), none[2].value);
    try testing.expectEqual(@as(u32, 0xbeef_beef), all[2].value);
}

test "the factor walks the answer from none to the whole headroom" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);

    var shader = GsShader{};
    shader.init(64, true);

    // A factor of zero asks for nothing past the guaranteed occupancy, so both
    // fields stay clear however large the budget is.
    var lowest = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&lowest, shader.pointer(), 0x8000, 0.0));
    try testing.expectEqual(@as(u32, 0), lowest[0].value);
    try testing.expectEqual(@as(u32, 0), lowest[1].value);

    // A negative factor cannot ask for less than nothing.
    var negative = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&negative, shader.pointer(), 0x8000, -4.0));
    try testing.expectEqual(@as(u32, 0), negative[0].value);
    try testing.expectEqual(@as(u32, 0), negative[1].value);

    // A factor of one takes the whole headroom, and the answer grows with it.
    var middle = oversubscriptionOut();
    var highest = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&middle, shader.pointer(), 0x8000, 0.5));
    try testing.expectEqual(errno.ok, get(&highest, shader.pointer(), 0x8000, 1.0));
    const middle_total = middle[0].value + (middle[1].value >> 16);
    const highest_total = highest[0].value + (highest[1].value >> 16);
    try testing.expect(highest_total >= middle_total);

    // Neither field can exceed its width, whatever the factor.
    for ([_]f32{ 2.0, 1000.0, 1e30, std.math.inf(f32) }) |factor| {
        var out = oversubscriptionOut();
        try testing.expectEqual(errno.ok, get(&out, shader.pointer(), 0x8000, factor));
        try testing.expectEqual(@as(u32, 0), out[0].value & ~full_pc_oversubscription);
        try testing.expectEqual(@as(u32, 0), out[1].value & ~full_sh_oversubscription);
    }

    // A factor that is not a number leaves the target at the guaranteed
    // occupancy rather than trapping on the conversion.
    var nan_out = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&nan_out, shader.pointer(), 0x8000, std.math.nan(f32)));
    try testing.expectEqual(@as(u32, 0), nan_out[0].value);
    try testing.expectEqual(@as(u32, 0), nan_out[1].value);
}

test "wave size changes how much budget buys" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);

    // The same shader twice, differing only in the wave-size bit. A wave64
    // covers twice the work of a wave32, so the same budget buys half as many
    // subgroups -- and the guaranteed occupancy it has to beat is halved too.
    var wave32 = GsShader{};
    var wave64 = GsShader{};
    wave32.init(64, true);
    wave64.init(64, false);

    // This budget is one subgroup past what the wave32 shader is guaranteed
    // and exactly what the wave64 one is guaranteed, so it buys the first
    // some oversubscription and the second none at all.
    const budget: u32 = 0x4020;
    var out32 = oversubscriptionOut();
    var out64 = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&out32, wave32.pointer(), budget, 1.0));
    try testing.expectEqual(errno.ok, get(&out64, wave64.pointer(), budget, 1.0));

    try testing.expect(out32[0].value != out64[0].value);
    try testing.expectEqual(full_pc_oversubscription, out32[0].value);
    try testing.expectEqual(@as(u32, 0), out64[0].value);
    try testing.expectEqual(@as(u32, 0), out64[1].value);

    // Both answers are still well formed.
    try testing.expectEqual(@as(u32, 0), out32[0].value & ~full_pc_oversubscription);
    try testing.expectEqual(@as(u32, 0), out32[1].value & ~full_sh_oversubscription);

    // Raising the budget far enough lifts the wave64 shader over its own
    // threshold as well, which is the same mechanism one shift further along.
    var lifted = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&lifted, wave64.pointer(), 0x8000, 1.0));
    try testing.expect(lifted[0].value != 0 or lifted[1].value != 0);
}

test "a shader that declares no output is not a division" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);

    // Zero output per subgroup rounds to zero words, which is the divisor in
    // the occupancy calculation. It must not divide by it.
    var empty = GsShader{};
    empty.init(0, true);
    var out = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&out, empty.pointer(), 0x4000, 1.0));
    try testing.expectEqual(@as(u32, 0), out[0].value & ~full_pc_oversubscription);
    try testing.expectEqual(@as(u32, 0), out[1].value & ~full_sh_oversubscription);

    // The largest values the fields can hold do not overflow either.
    var huge = GsShader{};
    huge.init(0x3ff, true);
    huge.cx[0].value = 0x7ff << 11; // VGT_GS_ONCHIP_CNTL at its widest
    huge.cx[1].value = 0x1ff; // GE_NGG_SUBGRP_CNTL at its widest
    var huge_out = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&huge_out, huge.pointer(), std.math.maxInt(u32) - 1, 1.0));
    try testing.expectEqual(@as(u32, 0), huge_out[0].value & ~full_pc_oversubscription);
    try testing.expectEqual(@as(u32, 0), huge_out[1].value & ~full_sh_oversubscription);
}

test "oversubscription refuses what it cannot read and writes nothing" {
    const std = @import("std");
    const guest_memory = @import("memory");
    const kernel_memory = libs.kernel_memory;
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);
    const einval = errno.KernelError.einval.raw();
    const efault = errno.KernelError.efault.raw();

    var shader = GsShader{};
    shader.init(64, true);

    // No output array at all, and a budget that needs a shader but has none.
    try testing.expectEqual(einval, get(null, shader.pointer(), 0x1000, 1.0));
    var out = oversubscriptionOut();
    try testing.expectEqual(einval, get(&out, null, 0x1000, 1.0));
    try testing.expectEqual(@as(u32, 0xdead), out[0].offset);
    try testing.expectEqual(@as(u32, 0xbeef_beef), out[0].value);

    // With a real address space attached, a shader this process cannot read is
    // refused, and the output array is left exactly as it was: the shader is
    // proved readable before either entry is written.
    var address_space = try guest_memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        16 * kernel_memory.page_size,
    );
    defer address_space.deinit();
    kernel_memory.init(testing.allocator);
    defer kernel_memory.deinit();
    kernel_memory.attachAddressSpace(&address_space);
    defer kernel_memory.attachAddressSpace(null);

    const page = kernel_memory.page_size;
    const base = guest_memory.user.start;
    try address_space.mapFixed(base, page, .{ .read = true, .write = true }, .direct_memory, 0);

    const mapped_out: [*]PrimRegister = @ptrFromInt(base);
    mapped_out[0] = .{ .offset = 0xdead, .value = 0xbeef_beef };
    mapped_out[1] = .{ .offset = 0xdead, .value = 0xbeef_beef };

    const unmapped: *const anyopaque = @ptrFromInt(base + 8 * page);
    try testing.expectEqual(efault, get(mapped_out, unmapped, 0x1000, 1.0));
    try testing.expectEqual(@as(u32, 0xdead), mapped_out[0].offset);
    try testing.expectEqual(@as(u32, 0xbeef_beef), mapped_out[0].value);
    try testing.expectEqual(@as(u32, 0xdead), mapped_out[1].offset);

    // An output array running off the end of the mapping is refused too.
    const truncated: [*]PrimRegister = @ptrFromInt(base + page - @sizeOf(PrimRegister));
    try testing.expectEqual(efault, get(truncated, unmapped, 0x1000, 1.0));
}

test "asking twice gives the same answer" {
    const std = @import("std");
    const testing = std.testing;

    var db = Database{};
    defer db.deinit(testing.allocator);
    try registerAll(&db, testing.allocator);

    const get = try agcEntryPoint(&db, "NKIzURsgV7I", AgcGetGsOversubscription);

    var shader = GsShader{};
    shader.init(96, true);

    // Nothing is carried between calls, so the same question answers the same
    // way even into an array the previous answer already filled.
    var first = oversubscriptionOut();
    try testing.expectEqual(errno.ok, get(&first, shader.pointer(), 0x3000, 0.75));
    var second = first;
    try testing.expectEqual(errno.ok, get(&second, shader.pointer(), 0x3000, 0.75));
    try testing.expectEqual(first[0].value, second[0].value);
    try testing.expectEqual(first[1].value, second[1].value);
    try testing.expectEqual(first[0].offset, second[0].offset);
    try testing.expectEqual(first[1].offset, second[1].offset);

    // And a different question answers differently in the same array.
    try testing.expectEqual(errno.ok, get(&second, shader.pointer(), 0, 0.75));
    try testing.expectEqual(@as(u32, 0), second[0].value);
    try testing.expectEqual(@as(u32, 0), second[1].value);
}
