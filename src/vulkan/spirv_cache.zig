// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Reuse translations while keeping dynamic uniforms outside the cache key.
const std = @import("std");
const rdna2 = @import("rdna2");

const SharedModule = struct {
    allocator: std.mem.Allocator,
    module: rdna2.spirv.Module,
    references: usize = 1,

    fn release(self: *SharedModule) void {
        self.references -= 1;
        if (self.references != 0) return;
        const allocator = self.allocator;
        self.module.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Read-only shader words remain valid until release, including after cache
/// eviction or destruction. Like Cache, leases belong to the renderer thread.
pub const Lease = struct {
    shared: *SharedModule,

    pub const View = struct {
        words: []const u32,
        used_control_flow_fallback: bool,
        used_dispatcher: bool,
    };

    pub fn view(self: Lease) View {
        return .{
            .words = self.shared.module.words,
            .used_control_flow_fallback = self.shared.module.used_control_flow_fallback,
            .used_dispatcher = self.shared.module.used_dispatcher,
        };
    }

    pub fn release(self: Lease) void {
        self.shared.release();
    }
};

const Entry = struct {
    key: []u8,
    hash: u64,
    shared: *SharedModule,
    sequence: u64,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    key: std.ArrayList(u8) = .empty,
    bytes: usize = 0,
    sequence: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    maximum_bytes: usize = 64 * 1024 * 1024,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            allocator.free(entry.key);
            entry.shared.release();
        }
        self.entries.deinit(allocator);
        self.key.deinit(allocator);
        self.* = .{};
    }

    pub fn translate(
        self: *Cache,
        allocator: std.mem.Allocator,
        program: *const rdna2.Program,
        options: rdna2.spirv.Options,
        pipeline: rdna2.ir.PipelineOptions,
    ) rdna2.spirv.Error!rdna2.spirv.Module {
        const lease = try self.acquire(allocator, program, options, pipeline);
        defer lease.release();
        return cloneModule(allocator, lease.shared.module);
    }

    pub fn acquire(
        self: *Cache,
        allocator: std.mem.Allocator,
        program: *const rdna2.Program,
        options: rdna2.spirv.Options,
        pipeline: rdna2.ir.PipelineOptions,
    ) rdna2.spirv.Error!Lease {
        self.key.clearRetainingCapacity();
        // Include decoded instructions as well as code: NGG reconstruction and
        // uniform branch pruning can change instructions without changing code.
        try appendValue(&self.key, allocator, program.code);
        try appendValue(&self.key, allocator, program.instructions.items);
        try appendValue(&self.key, allocator, pipeline);
        var key_options = options;
        key_options.scalar_registers = &.{};
        key_options.storage_buffers = &.{};
        try appendValue(&self.key, allocator, key_options);
        try appendValue(&self.key, allocator, options.storage_buffers.len);
        for (options.storage_buffers) |binding| {
            var keyed = binding;
            // Bounds come from OpArrayLength on the live descriptor range.
            // The vertex-table marker is backend metadata; neither field is
            // read by translation or its binding validation.
            keyed.extent_bytes = null;
            keyed.use_vertex_index = false;
            try appendValue(&self.key, allocator, keyed);
        }
        try appendValue(&self.key, allocator, options.scalar_registers.len);
        for (options.scalar_registers) |scalar| {
            var keyed = scalar;
            // The translator loads these values through the dynamic SSBO.
            // Register order and producer PC still select the SSBO word.
            if (options.dynamic_scalar_binding != null) keyed.value = 0;
            try appendValue(&self.key, allocator, keyed);
        }
        self.sequence +%= 1;
        const hash = std.hash.Wyhash.hash(0, self.key.items);
        for (self.entries.items) |*entry| {
            if (entry.hash != hash or !std.mem.eql(u8, entry.key, self.key.items)) continue;
            entry.sequence = self.sequence;
            self.hits += 1;
            entry.shared.references += 1;
            return .{ .shared = entry.shared };
        }
        self.misses += 1;
        const shared = try allocator.create(SharedModule);
        errdefer allocator.destroy(shared);
        shared.* = .{
            .allocator = allocator,
            .module = try rdna2.translateProgramSpirvWithPipelineOptions(allocator, program, options, pipeline),
        };
        errdefer shared.module.deinit(allocator);
        const size = self.key.items.len + shared.module.words.len * @sizeOf(u32);
        if (size > self.maximum_bytes) return .{ .shared = shared };
        while (self.entries.items.len != 0 and
            (self.bytes + size > self.maximum_bytes or self.entries.items.len >= 1024))
        {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |entry, index| {
                if (entry.sequence < self.entries.items[oldest].sequence) oldest = index;
            }
            const victim = self.entries.swapRemove(oldest);
            self.bytes -= victim.key.len + victim.shared.module.words.len * @sizeOf(u32);
            allocator.free(victim.key);
            victim.shared.release();
        }
        const key = try allocator.dupe(u8, self.key.items);
        errdefer allocator.free(key);
        try self.entries.append(allocator, .{ .key = key, .hash = hash, .shared = shared, .sequence = self.sequence });
        shared.references += 1; // The cache and the returned lease each own a reference.
        self.bytes += size;
        return .{ .shared = shared };
    }
};

fn cloneModule(allocator: std.mem.Allocator, module: rdna2.spirv.Module) !rdna2.spirv.Module {
    var copy = module;
    copy.words = try allocator.dupe(u32, module.words);
    return copy;
}

test "cache leases survive eviction and cache destruction without copying shader words" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    var program = try rdna2.decodeProgram(a, &.{0xbf810000});
    defer program.deinit(a);
    const options = rdna2.spirv.Options{ .stage = .compute, .local_size = .{ 1, 1, 1 } };
    const first = try cache.acquire(a, &program, options, .{});
    defer first.release();
    const second = try cache.acquire(a, &program, options, .{});
    defer second.release();
    try std.testing.expect(first.view().words.ptr == second.view().words.ptr);
    var independent = try cache.translate(a, &program, options, .{});
    defer independent.deinit(a);
    try std.testing.expect(independent.words.ptr != first.view().words.ptr);
    const magic = independent.words[0];
    independent.words[0] = 0;
    try std.testing.expectEqual(magic, first.view().words[0]);
    independent.words[0] = magic;
    cache.maximum_bytes = cache.bytes;
    var changed = options;
    changed.local_size[0] = 2;
    const third = try cache.acquire(a, &program, changed, .{});
    defer third.release();
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expect(cache.entries.items[0].shared == third.shared);
    try std.testing.expectEqualSlices(u32, independent.words, first.view().words);
    cache.deinit(a);
    try std.testing.expectEqualSlices(u32, independent.words, second.view().words);
    var fresh = try rdna2.translateProgramSpirvWithPipelineOptions(a, &program, changed, .{});
    defer fresh.deinit(a);
    try std.testing.expectEqualSlices(u32, fresh.words, third.view().words);
    try std.testing.expectEqual(fresh.used_dispatcher, third.view().used_dispatcher);
    try std.testing.expectEqual(fresh.used_control_flow_fallback, third.view().used_control_flow_fallback);
}

test "cache lease owns an oversized uncached translation" {
    const a = std.testing.allocator;
    var cache = Cache{ .maximum_bytes = 0 };
    defer cache.deinit(a);
    var program = try rdna2.decodeProgram(a, &.{0xbf810000});
    defer program.deinit(a);
    const lease = try cache.acquire(a, &program, .{ .stage = .compute }, .{});
    defer lease.release();
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    cache.deinit(a);
    try std.testing.expectEqual(@as(u32, 0x07230203), lease.view().words[0]);
}

test "dynamic buffer extents share translations while address and format rules remain keyed" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    var program = try rdna2.decodeProgram(a, &.{ 0xe030_2000, 0x8002_0100, 0xbf81_0000 });
    defer program.deinit(a);
    var binding = [_]rdna2.spirv.StorageBufferBinding{.{ .resource_sgpr = 8, .descriptor_index = 0, .stride = 4, .extent_bytes = 16 }};
    const options = rdna2.spirv.Options{ .stage = .compute, .storage_buffers = &binding };
    const first = try cache.acquire(a, &program, options, .{});
    defer first.release();
    for ([_]?u32{ 64, null, 0, 1024 * 1024 }) |extent| {
        binding[0].extent_bytes = extent;
        binding[0].use_vertex_index = !binding[0].use_vertex_index;
        const hit = try cache.acquire(a, &program, options, .{});
        defer hit.release();
        try std.testing.expect(first.view().words.ptr == hit.view().words.ptr);
        var fresh = try rdna2.translateProgramSpirvWithPipelineOptions(a, &program, options, .{});
        defer fresh.deinit(a);
        try std.testing.expectEqualSlices(u32, fresh.words, hit.view().words);
    }
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    binding[0].stride = 8;
    const stride = try cache.acquire(a, &program, options, .{});
    defer stride.release();
    try std.testing.expectEqual(@as(u64, 2), cache.misses);
    try std.testing.expect(!std.mem.eql(u32, first.view().words, stride.view().words));
    binding[0].soffset_value = 4;
    const offset = try cache.acquire(a, &program, options, .{});
    defer offset.release();
    try std.testing.expectEqual(@as(u64, 3), cache.misses);
    // Invalid bindings must not become hits of a previously valid shape.
    binding[0].descriptor_index = options.descriptor_array_length;
    try std.testing.expectError(error.InvalidStorageBinding, cache.acquire(a, &program, options, .{}));
}

// Serialize fields, never padding or slice pointers. Keys are compared in full
// after hashing, so a hash collision cannot select another shader.
fn appendValue(key: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!void {
    // Reserve once for the whole object. Growing/checking the ArrayList for
    // every field of every decoded instruction costs more than a cache hit.
    const bytes = try key.addManyAsSlice(allocator, serializedSize(value));
    var cursor: [*]u8 = bytes.ptr;
    writeValue(&cursor, value);
    std.debug.assert(cursor == bytes.ptr + bytes.len);
}

fn fixedSize(comptime T: type) ?usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var size: usize = 0;
            for (info.fields) |field| size += fixedSize(field.type) orelse break :blk null;
            break :blk size;
        },
        .array => |info| if (fixedSize(info.child)) |size| size * info.len else null,
        .@"enum" => |info| fixedSize(info.tag_type),
        .bool => 1,
        .int, .float => @sizeOf(T),
        else => null,
    };
}

fn serializedSize(value: anytype) usize {
    if (comptime fixedSize(@TypeOf(value))) |size| return size;
    return switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| blk: {
            var size: usize = 0;
            inline for (info.fields) |field| size += serializedSize(@field(value, field.name));
            break :blk size;
        },
        .array => blk: {
            var size: usize = 0;
            for (value) |element| size += serializedSize(element);
            break :blk size;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (comptime fixedSize(info.child)) |size| break :blk @sizeOf(usize) + value.len * size;
                var size: usize = @sizeOf(usize);
                for (value) |element| size += serializedSize(element);
                break :blk size;
            },
            .one => serializedSize(value.*),
            else => @compileError("Unsupported shader cache pointer"),
        },
        .optional => if (value) |payload| 1 + serializedSize(payload) else 1,
        else => unreachable,
    };
}

fn writeValue(cursor: *[*]u8, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            writeValue(cursor, @field(value, field.name));
        },
        .array => for (value) |element| writeValue(cursor, element),
        .pointer => |info| switch (info.size) {
            .slice => {
                writeValue(cursor, value.len);
                for (value) |element| writeValue(cursor, element);
            },
            .one => writeValue(cursor, value.*),
            else => @compileError("Unsupported shader cache pointer"),
        },
        .optional => {
            writeValue(cursor, value != null);
            if (value) |payload| writeValue(cursor, payload);
        },
        .@"enum" => writeValue(cursor, @intFromEnum(value)),
        .bool => {
            cursor.*[0] = @intFromBool(value);
            cursor.* += 1;
        },
        .int => |info| {
            const UInt = std.meta.Int(.unsigned, info.bits);
            const Storage = std.meta.Int(.unsigned, @sizeOf(T) * 8);
            const bits: Storage = @as(UInt, @bitCast(value));
            @memcpy(cursor.*[0..@sizeOf(Storage)], std.mem.asBytes(&bits));
            cursor.* += @sizeOf(Storage);
        },
        .float => {
            const bits: std.meta.Int(.unsigned, @bitSizeOf(T)) = @bitCast(value);
            writeValue(cursor, bits);
        },
        else => @compileError("Unsupported shader cache value: " ++ @typeName(T)),
    }
}

test "dynamic uniform values reuse translation while bindings and literals invalidate it" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    const code = [_]u32{0xbf810000}; // s_endpgm
    var program = try rdna2.decodeProgram(a, &code);
    defer program.deinit(a);
    var scalar = [_]rdna2.spirv.ScalarRegister{.{ .register = 0, .value = 1 }};
    var options = rdna2.spirv.Options{ .stage = .fragment, .scalar_registers = &scalar, .dynamic_scalar_binding = .{ .binding = 10 } };
    var first = try cache.translate(a, &program, options, .{});
    defer first.deinit(a);
    scalar[0].value = 123;
    var second = try cache.translate(a, &program, options, .{});
    defer second.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqualSlices(u32, first.words, second.words);
    options.dynamic_scalar_binding = null;
    var third = try cache.translate(a, &program, options, .{});
    defer third.deinit(a);
    scalar[0].value = 456;
    var fourth = try cache.translate(a, &program, options, .{});
    defer fourth.deinit(a);
    try std.testing.expectEqual(@as(u64, 3), cache.misses);
    options.color_export_mappings[0] = 0xc6;
    var fifth = try cache.translate(a, &program, options, .{});
    defer fifth.deinit(a);
    try std.testing.expectEqual(@as(u64, 4), cache.misses);
}

test "compute cache matches fresh translation across runtime values wave modes and buffer bounds" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(a);
    // The compare overwrites s7 only in wave64. Store that neighboring scalar
    // so an incorrectly reused wave32 module changes observable shader output.
    try program.instructions.appendSlice(a, &.{
        .{ .pc = 0, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 0 }, .src0 = .{ .kind = .sgpr, .reg = 0 }, .src_count = 1 },
        .{ .pc = 4, .family = .vop3, .opcode = .v_cmp_eq_u32, .dst = .{ .kind = .sgpr, .reg = 6 }, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 2 },
        .{ .pc = 12, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .sgpr, .reg = 7 }, .src_count = 1 },
        .{ .pc = 16, .word_count = 2, .family = .mubuf, .opcode = .buffer_store_dword, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = .{ .kind = .sgpr, .reg = 12 }, .src2 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 3 },
        .{ .pc = 24, .family = .sopp, .opcode = .s_endpgm },
    });
    var scalars = [_]rdna2.spirv.ScalarRegister{ .{ .register = 0, .value = 0 }, .{ .register = 7, .value = 0x1234_5678 } };
    var storage = [_]rdna2.spirv.StorageBufferBinding{.{ .resource_sgpr = 12, .descriptor_index = 0, .extent_bytes = 64 }};
    var options = rdna2.spirv.Options{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .scalar_registers = &scalars,
        .storage_buffers = &storage,
        .dynamic_scalar_binding = .{ .binding = 10 },
    };
    for (0..6) |step| {
        switch (step) {
            1 => scalars[0].value = 1,
            2 => options.wave32 = true,
            3 => options.local_size = .{ 32, 1, 1 },
            4 => storage[0].extent_bytes = 16,
            5 => storage[0].descriptor_index = 1,
            else => {},
        }
        var cached = try cache.translate(a, &program, options, .{});
        defer cached.deinit(a);
        var fresh = try rdna2.translateProgramSpirvWithPipelineOptions(a, &program, options, .{});
        defer fresh.deinit(a);
        try std.testing.expectEqualSlices(u32, fresh.words, cached.words);
    }
    try std.testing.expectEqual(@as(u64, 2), cache.hits);
    try std.testing.expectEqual(@as(u64, 4), cache.misses);
}
