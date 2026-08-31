// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Minimal PSML/MFSR resource lifecycle.
//!
//! PSML builds dispatch packets for the console's machine-learning block. The
//! host renderer cannot execute that block yet, but titles still need coherent
//! memory requirements and object lifetimes before they can select a fallback
//! reconstruction path. This module preserves those CPU-visible contracts and
//! accepts dispatch bookkeeping without inventing an accelerated result.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");

const error_not_initialized: i32 = @bitCast(@as(u32, 0x8a81_0001));
const error_invalid_object: i32 = @bitCast(@as(u32, 0x8a81_0005));
const error_invalid_pointer: i32 = @bitCast(@as(u32, 0x8a81_0009));
const error_invalid_value: i32 = @bitCast(@as(u32, 0x8a81_000d));
const error_null_object: i32 = @bitCast(@as(u32, 0x8a81_0014));

const shared_resources_magic: u32 = 0xa9c4;
const context_magic: u32 = 0x9231;
const main_memory_block_size: u64 = 0x20_0000;
const main_memory_alignment: u64 = 0x20_0000;
const extra_virtual_address_bytes: u64 = 0x60_0000;

const MainMemoryRequirements = extern struct {
    block_size: u64,
    alignment: u64,
    block_count: u64,
};

const MainMemoryParameters = extern struct {
    kind: u32,
    reserved: u32,
};

const DirectMemoryBlock = extern struct {
    address: u64,
    size: u64,
};

const SharedResourcesInitParameters = extern struct {
    kind: u32,
    reserved: u32,
    blocks: ?[*]const DirectMemoryBlock,
    block_count: u64,
    virtual_address_start: u64,
};

var initialized = std.atomic.Value(bool).init(false);
var shared_resource_count = std.atomic.Value(i32).init(0);

pub fn reset() void {
    initialized.store(false, .release);
    shared_resource_count.store(0, .release);
}

fn baseVirtualAddressBytes(kind: u32) u64 {
    return switch (kind) {
        0 => 0x0620_0000,
        1 => 0x1820_0000,
        2 => 0x1220_0000,
        else => 0,
    };
}

fn requiredBlockCount(kind: u32) u64 {
    const base = baseVirtualAddressBytes(kind);
    return if (base == 0) 0 else (base + extra_virtual_address_bytes) / main_memory_block_size;
}

fn requireInitialized() ?i32 {
    return if (initialized.load(.acquire)) null else error_not_initialized;
}

fn accessible(pointer: anytype, size: usize) bool {
    return pointer != null and kernel_memory.isGuestRangeAccessible(@intFromPtr(pointer.?), size);
}

fn initialize() callconv(abi.guest) i32 {
    initialized.store(true, .release);
    shared_resource_count.store(0, .release);
    return errno.ok;
}

fn getMainMemoryRequirements(
    output: ?*MainMemoryRequirements,
    parameters: ?*const MainMemoryParameters,
) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!accessible(output, @sizeOf(MainMemoryRequirements)) or
        !accessible(parameters, @sizeOf(MainMemoryParameters)))
    {
        return error_invalid_pointer;
    }
    const kind = parameters.?.kind;
    const count = requiredBlockCount(kind);
    if (count == 0) return error_invalid_value;
    output.?.* = .{
        .block_size = main_memory_block_size,
        .alignment = main_memory_alignment,
        .block_count = count,
    };
    return errno.ok;
}

fn sharedResourcesInitialize(
    resources: ?[*]u8,
    parameters: ?*const SharedResourcesInitParameters,
) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!accessible(resources, 0x30) or
        !accessible(parameters, @sizeOf(SharedResourcesInitParameters)))
    {
        return error_invalid_pointer;
    }
    const input = parameters.?;
    if (input.blocks == null or input.reserved != 0 or
        input.block_count < requiredBlockCount(input.kind) or
        requiredBlockCount(input.kind) == 0)
    {
        return error_invalid_value;
    }
    const bytes = resources.?;
    @memset(bytes[0..0x30], 0);
    std.mem.writeInt(u32, bytes[0x00..0x04], shared_resources_magic, .little);
    std.mem.writeInt(u64, bytes[0x08..0x10], @intFromPtr(input.blocks.?), .little);
    std.mem.writeInt(u64, bytes[0x18..0x20], input.block_count, .little);
    std.mem.writeInt(u32, bytes[0x20..0x24], input.kind, .little);
    std.mem.writeInt(u64, bytes[0x28..0x30], input.virtual_address_start, .little);
    _ = shared_resource_count.fetchAdd(1, .monotonic);
    return errno.ok;
}

fn sharedResourcesFinalize(resources: ?[*]u8) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (resources == null) return error_null_object;
    if (!accessible(resources, @sizeOf(u32))) return error_invalid_pointer;
    if (std.mem.readInt(u32, resources.?[0..4], .little) != shared_resources_magic) {
        return error_invalid_object;
    }
    resources.?[0..4].* = [_]u8{0} ** 4;
    _ = shared_resource_count.fetchSub(1, .monotonic);
    return errno.ok;
}

fn getContextMemoryRequirements(
    output: ?*MainMemoryRequirements,
    _: u64,
) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!accessible(output, @sizeOf(MainMemoryRequirements))) return error_invalid_pointer;
    output.?.* = .{
        .block_size = main_memory_block_size,
        .alignment = main_memory_alignment,
        .block_count = 1,
    };
    return errno.ok;
}

fn contextInitialize(context: ?[*]u8, parameters: ?[*]const u8) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!accessible(context, 0x370) or !accessible(parameters, 0x10)) return error_invalid_pointer;
    const shared_resources = std.mem.readInt(u64, parameters.?[0x08..0x10], .little);
    if (shared_resources == 0 or
        !kernel_memory.isGuestRangeAccessible(shared_resources, @sizeOf(u32)))
    {
        return error_invalid_pointer;
    }
    const bytes = context.?;
    std.mem.writeInt(u32, bytes[0x00..0x04], context_magic, .little);
    std.mem.writeInt(u64, bytes[0x360..0x368], shared_resources, .little);
    bytes[0x368] = 0;
    return errno.ok;
}

fn objectMagic(object: ?[*]const u8) ?u32 {
    if (!accessible(object, @sizeOf(u32))) return null;
    return std.mem.readInt(u32, object.?[0..4], .little);
}

fn validObject(object: ?[*]const u8) bool {
    const magic = objectMagic(object) orelse return false;
    return magic == shared_resources_magic or magic == context_magic;
}

fn contextFinalize(context: ?[*]u8) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!validObject(context)) return error_invalid_object;
    context.?[0..4].* = [_]u8{0} ** 4;
    return errno.ok;
}

fn getWorkAreaSize(object: ?[*]const u8, output: ?*u32) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!validObject(object)) return error_invalid_object;
    if (!accessible(output, @sizeOf(u32))) return error_invalid_pointer;
    output.?.* = 0x600;
    return errno.ok;
}

fn dispatch(context: ?[*]const u8, command: u64, parameters: u64) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!validObject(context)) return error_invalid_object;
    if (command == 0 or parameters == 0) return error_invalid_pointer;
    return errno.ok;
}

fn getProgress(object: ?[*]const u8, output: ?*f32, _: u32) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    if (!validObject(object)) return error_invalid_object;
    if (!accessible(output, @sizeOf(f32))) return error_invalid_pointer;
    output.?.* = 0.0;
    return errno.ok;
}

fn requestCapture(object: ?[*]const u8) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    return if (validObject(object)) errno.ok else error_invalid_object;
}

fn validateObject(object: ?[*]const u8) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    return if (validObject(object)) errno.ok else error_invalid_object;
}

pub const exports = [_]symbols.Export{
    .{ .name = "scePsmlMfsrInit", .function = trace.wrap("scePsmlMfsrInit", &initialize), .expect_id = "3WVD91e12ZQ" },
    .{ .name = "scePsmlMfsrGetSharedResourcesInitRequirement", .function = trace.wrap("scePsmlMfsrGetSharedResourcesInitRequirement", &getMainMemoryRequirements), .expect_id = "+2KpvixvL6E" },
    .{ .name = "scePsmlMfsrCreateSharedResources", .function = trace.wrap("scePsmlMfsrCreateSharedResources", &sharedResourcesInitialize), .expect_id = "eWoKNeB6V-k" },
    .{ .name = "libScePsml:jEevBXmagOQ", .function = trace.wrap("scePsmlSharedResourcesFinalize", &sharedResourcesFinalize), .id_override = "jEevBXmagOQ" },
    .{ .name = "libScePsml:VGjrQa-WqdU", .function = trace.wrap("scePsmlGetContextMemoryRequirements", &getContextMemoryRequirements), .id_override = "VGjrQa-WqdU" },
    .{ .name = "libScePsml:fccGInHrj8A", .function = trace.wrap("scePsmlContextInitialize", &contextInitialize), .id_override = "fccGInHrj8A" },
    .{ .name = "libScePsml:JaLBe0P3jSU", .function = trace.wrap("scePsmlContextFinalize", &contextFinalize), .id_override = "JaLBe0P3jSU" },
    .{ .name = "scePsmlMfsrGetDispatchMfsrPacketSizeInDwords", .function = trace.wrap("scePsmlGetWorkAreaSize", &getWorkAreaSize), .expect_id = "AHalTX9wFZY" },
    .{ .name = "scePsmlMfsrGetDispatchMfsrPacket900", .function = trace.wrap("scePsmlDispatch900", &dispatch), .expect_id = "RUNLFro+qok" },
    .{ .name = "scePsmlMfsrGetDispatchMfsrPacket1000", .function = trace.wrap("scePsmlDispatch1000", &dispatch), .expect_id = "s2psNHUIdjk" },
    .{ .name = "scePsmlMfsrGetDispatchMfsrPacket1100", .function = trace.wrap("scePsmlDispatch1100", &dispatch), .expect_id = "94iBp3KvIuI" },
    .{ .name = "libScePsml:GHna9-DvnUk", .function = trace.wrap("scePsmlGetProgress", &getProgress), .id_override = "GHna9-DvnUk" },
    .{ .name = "libScePsml:GJY0MvuTcs8", .function = trace.wrap("scePsmlRequestCapture", &requestCapture), .id_override = "GJY0MvuTcs8" },
    .{ .name = "libScePsml:LXq+6mIxpCw", .function = trace.wrap("scePsmlValidateObject", &validateObject), .id_override = "LXq+6mIxpCw" },
    .{ .name = "libScePsml:FSGaTQze0UY", .function = trace.wrap("scePsmlValidateObject2", &validateObject), .id_override = "FSGaTQze0UY" },
};

test "PSML reports deterministic memory requirements" {
    reset();
    try std.testing.expectEqual(errno.ok, initialize());
    const parameters = MainMemoryParameters{ .kind = 0, .reserved = 0 };
    var requirements: MainMemoryRequirements = undefined;
    // Unit-test memory is outside the guest arena, so exercise the pure count
    // contract directly rather than the guest-pointer validation boundary.
    _ = parameters;
    _ = &requirements;
    try std.testing.expectEqual(@as(u64, 52), requiredBlockCount(0));
    try std.testing.expectEqual(@as(u64, 148), requiredBlockCount(2));
}
