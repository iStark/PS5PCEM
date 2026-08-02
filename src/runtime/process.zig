// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! PS5 process-entry parameter construction.
//!
//! The guest entry ABI receives a pointer to a fixed 0x20-byte structure in
//! RDI rather than a Linux-style argc/argv/envp/auxv stack. The structure owns
//! three inline argv pointers: the image name and at most two compatibility
//! arguments. Strings and the structure live at the top of the mapped initial
//! pthread stack, above the downward-growing execution area.

const std = @import("std");
const memory = @import("memory");

pub const maximum_arguments: usize = 3;

pub const Error = error{
    InvalidArgument,
    TooManyArguments,
    StackOverflow,
} || memory.Error;

pub const EntryParams = extern struct {
    argc: u32,
    padding: u32 = 0,
    argv: [maximum_arguments]u64 = [_]u64{0} ** maximum_arguments,
};

comptime {
    std.debug.assert(@sizeOf(EntryParams) == 0x20);
    std.debug.assert(@offsetOf(EntryParams, "argv") == 0x08);
}

pub const Options = struct {
    image_name: []const u8 = "eboot.bin",
    /// Additional arguments after argv[0]. The ABI permits at most two.
    arguments: []const []const u8 = &.{},
};

pub const Layout = struct {
    params_address: u64,
    /// RSP immediately before the native bridge CALL. The call pushes its
    /// return address at params_address - 8, matching the AMD64 entry alignment.
    stack_pointer: u64,
    params: EntryParams,
};

pub fn buildEntryLayout(
    address_space: *memory.AddressSpace,
    stack_address: u64,
    stack_size: u64,
    options: Options,
) Error!Layout {
    if (stack_address == 0 or stack_size == 0 or
        options.image_name.len == 0 or containsNul(options.image_name))
    {
        return error.InvalidArgument;
    }
    if (options.arguments.len > maximum_arguments - 1) {
        return error.TooManyArguments;
    }
    for (options.arguments) |argument| {
        if (containsNul(argument)) return error.InvalidArgument;
    }

    const stack_end = std.math.add(u64, stack_address, stack_size) catch
        return error.StackOverflow;
    var values: [maximum_arguments][]const u8 = undefined;
    values[0] = options.image_name;
    @memcpy(values[1 .. options.arguments.len + 1], options.arguments);
    const argument_count = options.arguments.len + 1;

    var params = EntryParams{ .argc = @intCast(argument_count) };
    var cursor = stack_end;
    var index = argument_count;
    while (index > 0) {
        index -= 1;
        const value = values[index];
        const storage_size = std.math.add(u64, @intCast(value.len), 1) catch
            return error.StackOverflow;
        if (storage_size > cursor -| stack_address) return error.StackOverflow;
        cursor = std.mem.alignBackward(u64, cursor - storage_size, 16);
        if (cursor < stack_address) return error.StackOverflow;
        try address_space.write(cursor, value);
        try address_space.writeInt(u8, cursor + @as(u64, @intCast(value.len)), 0);
        params.argv[index] = cursor;
    }

    if (@sizeOf(EntryParams) + 16 > cursor -| stack_address) {
        return error.StackOverflow;
    }
    const params_address = std.mem.alignBackward(
        u64,
        cursor - @sizeOf(EntryParams),
        16,
    );
    // Reserve one word below the pre-call RSP for the bridge's return address.
    if (params_address < stack_address + 8) return error.StackOverflow;
    try address_space.write(params_address, std.mem.asBytes(&params));

    return .{
        .params_address = params_address,
        .stack_pointer = params_address,
        .params = params,
    };
}

fn containsNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "entry layout stores the fixed parameter block and three argv strings" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const stack_address = memory.system_managed.start;
    try address_space.mapFixed(
        stack_address,
        memory.page_size,
        .read_write,
        .private,
        null,
    );

    const layout = try buildEntryLayout(
        &address_space,
        stack_address,
        memory.page_size,
        .{
            .image_name = "eboot.bin",
            .arguments = &.{ "-safe", "profile=1" },
        },
    );
    try testing.expectEqual(@as(u64, 0), layout.stack_pointer & 0xf);
    try testing.expectEqual(layout.params_address, layout.stack_pointer);
    try testing.expectEqual(@as(u32, 3), layout.params.argc);

    var encoded: [@sizeOf(EntryParams)]u8 = undefined;
    try address_space.read(layout.params_address, &encoded);
    const stored = std.mem.bytesToValue(EntryParams, &encoded);
    try testing.expectEqual(@as(u32, 3), stored.argc);
    try expectGuestString(&address_space, stored.argv[0], "eboot.bin");
    try expectGuestString(&address_space, stored.argv[1], "-safe");
    try expectGuestString(&address_space, stored.argv[2], "profile=1");
}

test "entry layout rejects arguments beyond the inline ABI capacity" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    try testing.expectError(
        error.TooManyArguments,
        buildEntryLayout(
            &address_space,
            memory.system_managed.start,
            memory.page_size,
            .{ .arguments = &.{ "one", "two", "three" } },
        ),
    );
}

fn expectGuestString(
    address_space: *memory.AddressSpace,
    address: u64,
    expected: []const u8,
) !void {
    var buffer: [32]u8 = [_]u8{0} ** 32;
    try address_space.read(address, buffer[0 .. expected.len + 1]);
    try testing.expectEqualStrings(expected, buffer[0..expected.len]);
    try testing.expectEqual(@as(u8, 0), buffer[expected.len]);
}
