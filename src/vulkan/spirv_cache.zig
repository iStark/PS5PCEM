// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Reuse translations while keeping dynamic uniforms outside the cache key.
const std = @import("std");
const rdna2 = @import("rdna2");

pub var reuse_program_hash_state = std.atomic.Value(bool).init(true);

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

    /// Takes ownership even if allocating the lease fails. This lets generated
    /// fallback shaders share the same lifetime handling as cached shaders.
    pub fn fromOwned(allocator: std.mem.Allocator, module: rdna2.spirv.Module) std.mem.Allocator.Error!Lease {
        var owned = module;
        errdefer owned.deinit(allocator);
        const shared = try allocator.create(SharedModule);
        shared.* = .{ .allocator = allocator, .module = owned };
        return .{ .shared = shared };
    }

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

    /// Independent owners can retain the immutable module without copying it.
    pub fn retain(self: Lease) Lease {
        self.shared.references += 1;
        return self;
    }

    pub fn sameModule(self: Lease, other: Lease) bool {
        return self.shared == other.shared;
    }
};

const Entry = struct {
    key: []u8,
    hash: u64,
    shared: *SharedModule,
    sequence: u64,
    program_identity: u64 = 0,
    program_prefix_length: usize = 0,
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
        return self.acquirePrepared(allocator, program, options, pipeline, null);
    }

    /// The optional prefix belongs to this exact immutable program and pipeline.
    /// Cache entries still own and compare the complete canonical key bytes.
    pub fn acquirePrepared(
        self: *Cache,
        allocator: std.mem.Allocator,
        program: *const rdna2.Program,
        options: rdna2.spirv.Options,
        pipeline: rdna2.ir.PipelineOptions,
        prepared: ?rdna2.cache_key.ProgramKey,
    ) rdna2.spirv.Error!Lease {
        for (options.storage_buffers) |binding| if (binding.lookup != null) {
            // Invalid duplicate candidates must not alias a previously valid
            // entry after their runtime words are removed from the cache key.
            try rdna2.spirv.validateStorageBufferBindings(options.storage_buffers, options.descriptor_array_length);
            break;
        };
        self.key.clearRetainingCapacity();
        const borrowed = if (reuse_program_hash_state.load(.monotonic)) prepared else null;
        // Include decoded instructions as well as code: NGG reconstruction and
        // uniform branch pruning can change instructions without changing code.
        if (borrowed == null) {
            if (prepared) |prefix| {
                try self.key.appendSlice(allocator, prefix.bytes);
            } else {
                try appendValue(&self.key, allocator, program.code);
                try appendValue(&self.key, allocator, program.instructions.items);
                try appendValue(&self.key, allocator, pipeline);
            }
        }
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
            if (keyed.lookup != null) keyed.candidate_words = @splat(0);
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
        const prefix_length = if (borrowed) |prefix| prefix.bytes.len else 0;
        const key_length = prefix_length + self.key.items.len;
        const hash = if (borrowed) |prefix| hash: {
            var state = prefix.hash_state;
            state.update(self.key.items);
            break :hash state.final();
        } else std.hash.Wyhash.hash(0, self.key.items);
        for (self.entries.items) |*entry| {
            if (entry.hash != hash or entry.key.len != key_length or
                !std.mem.eql(u8, entry.key[prefix_length..], self.key.items)) continue;
            if (borrowed) |prefix| {
                // Entries own the full canonical bytes. A lifetime-unique ID
                // proves an already checked immutable prefix without retaining
                // its pointer. Independent owners still compare their content.
                if (prefix.identity == 0 or entry.program_identity != prefix.identity or
                    entry.program_prefix_length != prefix_length)
                {
                    if (!std.mem.eql(u8, entry.key[0..prefix_length], prefix.bytes)) continue;
                    entry.program_identity = prefix.identity;
                    entry.program_prefix_length = prefix_length;
                }
            }
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
        const size = key_length + shared.module.words.len * @sizeOf(u32);
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
        const key = try allocator.alloc(u8, key_length);
        errdefer allocator.free(key);
        if (borrowed) |prefix| @memcpy(key[0..prefix_length], prefix.bytes);
        @memcpy(key[prefix_length..], self.key.items);
        try self.entries.append(allocator, .{
            .key = key,
            .hash = hash,
            .shared = shared,
            .sequence = self.sequence,
            .program_identity = if (borrowed) |prefix| prefix.identity else 0,
            .program_prefix_length = prefix_length,
        });
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

test "owned translation leases preserve words and release them on allocation failure" {
    const a = std.testing.allocator;
    const words = try a.dupe(u32, &.{ 0x07230203, 17, 23 });
    const lease = try Lease.fromOwned(a, .{ .words = words, .used_control_flow_fallback = true });
    try std.testing.expect(lease.view().words.ptr == words.ptr);
    try std.testing.expectEqualSlices(u32, &.{ 0x07230203, 17, 23 }, lease.view().words);
    try std.testing.expect(lease.view().used_control_flow_fallback);
    lease.release();

    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    const f = failing.allocator();
    const failed_words = try f.dupe(u32, &.{ 0x07230203, 29 });
    try std.testing.expectError(error.OutOfMemory, Lease.fromOwned(f, .{ .words = failed_words }));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "retained translation owns immutable words after the original lease releases" {
    const a = std.testing.allocator;
    const words = try a.dupe(u32, &.{ 0x07230203, 17, 23 });
    const original = try Lease.fromOwned(a, .{ .words = words });
    const retained = original.retain();
    defer retained.release();
    try std.testing.expect(original.sameModule(retained));
    original.release();
    try std.testing.expect(retained.view().words.ptr == words.ptr);
    try std.testing.expectEqualSlices(u32, &.{ 0x07230203, 17, 23 }, retained.view().words);
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

test "runtime buffer lookup changes reuse words and still reject invalid candidates" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    var program = try rdna2.decodeProgram(a, &.{ 0xe030_2000, 0x8002_0100, 0xbf81_0000 });
    defer program.deinit(a);
    const table = rdna2.spirv.buffer_lookup.Binding{ .descriptor_index = 2, .word_offset = 7, .mask = 3, .probes = 4 };
    var bindings = [_]rdna2.spirv.StorageBufferBinding{
        .{ .resource_sgpr = 8, .descriptor_index = 0, .stride = 4, .candidate_words = .{ 0x1000, 0x40000, 4, 0x5204 }, .lookup = table },
        .{ .resource_sgpr = 8, .descriptor_index = 1, .stride = 4, .candidate_words = .{ 0x2000, 0x40000, 8, 0x5204 }, .lookup = table },
    };
    const options = rdna2.spirv.Options{ .stage = .compute, .storage_buffers = &bindings, .descriptor_array_length = 3 };
    const first = try cache.acquire(a, &program, options, .{});
    defer first.release();
    for (0..4) |word| {
        bindings[0].candidate_words.?[word] ^= 0x400;
        const hit = try cache.acquire(a, &program, options, .{});
        defer hit.release();
        try std.testing.expect(first.view().words.ptr == hit.view().words.ptr);
        var fresh = try rdna2.translateProgramSpirv(a, &program, options);
        defer fresh.deinit(a);
        try std.testing.expectEqualSlices(u32, first.view().words, fresh.words);
    }
    const saved = bindings[1];
    bindings[1].candidate_words = bindings[0].candidate_words;
    try std.testing.expectError(error.InvalidStorageBinding, cache.acquire(a, &program, options, .{}));
    bindings[1] = saved;
    bindings[1].lookup = null;
    try std.testing.expectError(error.InvalidStorageBinding, cache.acquire(a, &program, options, .{}));
    bindings[1] = saved;
    bindings[1].lookup.?.probes = 5;
    try std.testing.expectError(error.InvalidStorageBinding, cache.acquire(a, &program, options, .{}));
    bindings[1] = saved;
    bindings[1].lookup.?.mask = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidStorageBinding, cache.acquire(a, &program, options, .{}));
    bindings[1] = saved;
    bindings[1].lookup.?.word_offset = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidStorageBinding, cache.acquire(a, &program, options, .{}));
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    try std.testing.expectEqual(@as(u64, 4), cache.hits);
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

// Serialize fields, never padding or slice pointers. Hash matches require the
// canonical content; immutable lifetime IDs only reuse a checked prefix.
const appendValue = rdna2.cache_key.appendValue;

test "prepared key reuse survives owner destruction and verifies hash collisions" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    var program = try rdna2.decodeProgram(a, &.{ 0xbf800000, 0xbf810000 });
    defer program.deinit(a);
    const options = rdna2.spirv.Options{ .stage = .compute };
    var original_hash: std.hash.Wyhash = undefined;
    var original_identity: u64 = 0;
    {
        const key = try rdna2.cache_key.ProgramKey.init(a, &program, .{});
        defer key.deinit(a);
        original_hash = key.hash_state;
        original_identity = key.identity;
        const lease = try cache.acquirePrepared(a, &program, options, .{}, key);
        lease.release();
    }
    // A new equal owner may occupy the same allocator address; cache entries
    // keep their own bytes and must not dereference the destroyed prefix.
    const equal = try rdna2.cache_key.ProgramKey.init(a, &program, .{});
    defer equal.deinit(a);
    try std.testing.expect(equal.identity != original_identity);
    for ([_]bool{ true, false, true }) |reuse| {
        const previous = reuse_program_hash_state.swap(reuse, .monotonic);
        defer reuse_program_hash_state.store(previous, .monotonic);
        const lease = try cache.acquirePrepared(a, &program, options, .{}, equal);
        lease.release();
    }
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    const pipeline = rdna2.ir.PipelineOptions{ .enable_typed_ir = false };
    var different = try rdna2.cache_key.ProgramKey.init(a, &program, pipeline);
    defer different.deinit(a);
    try std.testing.expectEqual(equal.bytes.len, different.bytes.len);
    try std.testing.expect(!std.mem.eql(u8, equal.bytes, different.bytes));
    // Deliberately synthesize a hash collision with an equal-length prefix.
    different.hash_state = original_hash;
    const collision = try cache.acquirePrepared(a, &program, options, pipeline, different);
    defer collision.release();
    try std.testing.expectEqual(@as(u64, 2), cache.misses);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expectEqual(cache.entries.items[0].hash, cache.entries.items[1].hash);
    var fresh = try rdna2.translateProgramSpirvWithPipelineOptions(a, &program, options, pipeline);
    defer fresh.deinit(a);
    try std.testing.expectEqualSlices(u32, fresh.words, collision.view().words);
    // Even for an already verified identity, a suffix collision cannot hit.
    const changed = rdna2.spirv.Options{ .stage = .compute, .local_size = .{ 2, 1, 1 } };
    const changed_lease = try cache.acquirePrepared(a, &program, changed, pipeline, different);
    defer changed_lease.release();
    cache.entries.items[1].hash = cache.entries.items[2].hash;
    const again = try cache.acquirePrepared(a, &program, changed, pipeline, different);
    defer again.release();
    try std.testing.expect(again.view().words.ptr == changed_lease.view().words.ptr);
    try std.testing.expect(again.view().words.ptr != collision.view().words.ptr);
}

test "prepared program keys match fresh translations across reconstructed instructions and pipeline changes" {
    const a = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(a);
    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(a);
    try program.instructions.appendSlice(a, &.{
        .{ .pc = 0, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 0 }, .src0 = .{ .kind = .integer_inline_constant, .value = 7 }, .src_count = 1 },
        .{ .pc = 4, .word_count = 2, .family = .mubuf, .opcode = .buffer_store_dword, .dst = .{ .kind = .vgpr, .reg = 0 }, .src0 = .{ .kind = .vgpr, .reg = 1 }, .src1 = .{ .kind = .sgpr, .reg = 12 }, .src2 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 3 },
        .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm },
    });
    const storage = [_]rdna2.spirv.StorageBufferBinding{.{ .resource_sgpr = 12, .descriptor_index = 0, .extent_bytes = 64 }};
    const options = rdna2.spirv.Options{ .stage = .compute, .storage_buffers = &storage };
    for (0..3) |step| {
        // Reconstructed/pruned instructions can change without any code words.
        program.instructions.items[0].src0.value = if (step == 0) 7 else 19;
        const pipeline = rdna2.ir.PipelineOptions{ .enable_typed_ir = step == 2 };
        const prefix = try rdna2.cache_key.ProgramKey.init(a, &program, pipeline);
        defer prefix.deinit(a);
        const cached = try cache.acquirePrepared(a, &program, options, pipeline, prefix);
        defer cached.release();
        const ordinary = try cache.acquire(a, &program, options, pipeline);
        defer ordinary.release();
        try std.testing.expect(cached.view().words.ptr == ordinary.view().words.ptr);
        var fresh = try rdna2.translateProgramSpirvWithPipelineOptions(a, &program, options, pipeline);
        defer fresh.deinit(a);
        try std.testing.expectEqualSlices(u32, fresh.words, cached.view().words);
        try std.testing.expectEqual(@as(u64, @intCast(step + 1)), cache.misses);
        try std.testing.expectEqual(@as(u64, @intCast(step + 1)), cache.hits);
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
