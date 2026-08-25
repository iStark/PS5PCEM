// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! API-neutral ownership and invalidation for guest image allocations.
//!
//! A single guest byte range may be described as a colour target, storage
//! image and sampled texture during one frame. Vulkan does not alias the
//! separately-created `VkImage`s for us, so every cached representation is
//! registered here and observes one monotonically increasing content epoch.

const std = @import("std");

pub const Token = u64;

pub const Kind = enum {
    color_target,
    depth_target,
    storage_image,
    sampled_image,
};

pub const Aspect = enum {
    color,
    depth,
    depth_stencil,
};

pub const Range = struct {
    address: u64,
    size: u64,

    pub fn end(self: Range) u64 {
        return self.address +| self.size;
    }

    pub fn valid(self: Range) bool {
        return self.size != 0;
    }

    pub fn overlaps(self: Range, other: Range) bool {
        if (!self.valid() or !other.valid()) return false;
        return self.address < other.end() and other.address < self.end();
    }

    pub fn eql(self: Range, other: Range) bool {
        return self.address == other.address and self.size == other.size;
    }
};

/// Storage identity of an image view. Swizzles and sampler state deliberately
/// do not appear here: they change interpretation, not the occupied bytes.
pub const Signature = struct {
    format: u32,
    width: u32,
    height: u32,
    depth: u32 = 1,
    mip_levels: u8 = 1,
    layers: u16 = 1,
    tile_mode: u8 = 0,
    samples_log2: u8 = 0,
    aspect: Aspect = .color,

    pub fn eql(self: Signature, other: Signature) bool {
        return std.meta.eql(self, other);
    }
};

pub const Entry = struct {
    token: Token,
    kind: Kind,
    range: Range,
    signature: Signature,
    /// Last content epoch observed by this representation or any overlapping
    /// representation. Cached readers compare this with their upload epoch.
    generation: u64,
    /// Content epoch physically present in this particular host image.
    resident_generation: u64,
    /// Representation that most recently produced the bytes. Token zero means
    /// guest memory is the canonical source after an explicit writeback.
    authority: Token,
};

pub const Resolve = struct {
    source: Token,
    destination: Token,
    generation: u64,
    direct: bool,
};

const Newest = struct {
    generation: u64,
    authority: Token,
};

pub const Manager = struct {
    entries: std.ArrayList(Entry) = .empty,
    next_token: Token = 1,
    next_generation: u64 = 1,
    enabled: bool = true,
    canonical_authority_enabled: bool = true,

    pub fn deinit(self: *Manager, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn register(
        self: *Manager,
        allocator: std.mem.Allocator,
        kind: Kind,
        range: Range,
        signature: Signature,
    ) std.mem.Allocator.Error!Token {
        const token = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        const inherited = self.newestForRange(range);
        try self.entries.append(allocator, .{
            .token = token,
            .kind = kind,
            .range = range,
            .signature = signature,
            .generation = inherited.generation,
            .resident_generation = 0,
            .authority = if (self.canonical_authority_enabled) inherited.authority else 0,
        });
        return token;
    }

    pub fn unregister(self: *Manager, token: Token) void {
        for (self.entries.items, 0..) |candidate, index| {
            if (candidate.token != token) continue;
            _ = self.entries.swapRemove(index);
            for (self.entries.items) |*dependent| {
                if (dependent.authority != token) continue;
                dependent.authority = self.residentAuthority(
                    dependent.range,
                    dependent.generation,
                );
            }
            return;
        }
    }

    pub fn entry(self: *const Manager, token: Token) ?Entry {
        for (self.entries.items) |candidate| {
            if (candidate.token == token) return candidate;
        }
        return null;
    }

    pub fn tokenOverlaps(self: *const Manager, token: Token, range: Range) bool {
        const candidate = self.entry(token) orelse return false;
        return candidate.range.overlaps(range);
    }

    pub fn compatibleAlias(
        self: *const Manager,
        token: Token,
        range: Range,
        signature: Signature,
    ) bool {
        const candidate = self.entry(token) orelse return false;
        return candidate.range.eql(range) and candidate.signature.eql(signature);
    }

    pub fn generationForToken(self: *const Manager, token: Token) u64 {
        if (!self.enabled) return 0;
        return if (self.entry(token)) |candidate| candidate.generation else 0;
    }

    pub fn generationForRange(self: *const Manager, range: Range) u64 {
        if (!self.enabled) return 0;
        return self.newestForRange(range).generation;
    }

    pub fn authorityForRange(self: *const Manager, range: Range) Token {
        if (!self.enabled or !self.canonical_authority_enabled) return 0;
        return self.newestForRange(range).authority;
    }

    fn newestForRange(self: *const Manager, range: Range) Newest {
        var result = Newest{ .generation = 0, .authority = 0 };
        for (self.entries.items) |candidate| {
            if (!candidate.range.overlaps(range) or candidate.generation < result.generation) continue;
            result = .{ .generation = candidate.generation, .authority = candidate.authority };
        }
        return result;
    }

    fn residentAuthority(self: *const Manager, range: Range, generation: u64) Token {
        for (self.entries.items) |candidate| {
            if (candidate.range.overlaps(range) and candidate.resident_generation == generation) {
                return candidate.token;
            }
        }
        return 0;
    }

    /// Makes the writer authoritative and invalidates every overlapping cached
    /// representation, including aliases whose base addresses differ.
    pub fn markWrite(self: *Manager, token: Token) u64 {
        if (!self.enabled) return 0;
        const writer = self.entry(token) orelse return 0;
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        for (self.entries.items) |*candidate| {
            if (!candidate.range.overlaps(writer.range)) continue;
            candidate.generation = generation;
            candidate.authority = if (self.canonical_authority_enabled) token else 0;
            if (candidate.token == token) candidate.resident_generation = generation;
        }
        return generation;
    }

    /// Records that a representation has imported the current canonical
    /// content, either by a direct Vulkan copy/resolve or from guest memory.
    pub fn markSynchronized(self: *Manager, token: Token) bool {
        if (!self.enabled) return false;
        for (self.entries.items) |*candidate| {
            if (candidate.token != token) continue;
            candidate.resident_generation = candidate.generation;
            return true;
        }
        return false;
    }

    /// Chooses the cheapest legal synchronization for a stale representation.
    /// `direct` is true only when source and destination describe exactly the
    /// same storage; reinterpretations and partial overlaps go through guest
    /// memory so tiling/format conversion remains explicit.
    pub fn resolve(self: *const Manager, token: Token) ?Resolve {
        if (!self.enabled) return null;
        const destination = self.entry(token) orelse return null;
        if (destination.resident_generation == destination.generation) return null;
        const source = if (self.canonical_authority_enabled)
            self.entry(destination.authority)
        else
            null;
        return .{
            .source = if (source != null) destination.authority else 0,
            .destination = token,
            .generation = destination.generation,
            .direct = if (source) |canonical|
                canonical.range.eql(destination.range) and canonical.signature.eql(destination.signature)
            else
                false,
        };
    }

    /// Makes guest memory an up-to-date canonical backing store for all
    /// overlapping views without discarding still-resident Vulkan copies.
    pub fn publishGuest(self: *Manager, range: Range) void {
        if (!self.enabled) return;
        for (self.entries.items) |*candidate| {
            if (candidate.range.overlaps(range)) candidate.authority = 0;
        }
    }
};

const test_signature = Signature{
    .format = 37,
    .width = 64,
    .height = 64,
};

test "partial image aliases share write generations" {
    var manager = Manager{};
    defer manager.deinit(std.testing.allocator);
    const color = try manager.register(
        std.testing.allocator,
        .color_target,
        .{ .address = 0x10000, .size = 0x8000 },
        test_signature,
    );
    const sampled = try manager.register(
        std.testing.allocator,
        .sampled_image,
        .{ .address = 0x14000, .size = 0x8000 },
        test_signature,
    );

    const generation = manager.markWrite(color);
    try std.testing.expect(generation != 0);
    try std.testing.expectEqual(generation, manager.generationForToken(sampled));
    try std.testing.expectEqual(generation, manager.generationForRange(.{
        .address = 0x17fff,
        .size = 2,
    }));
}

test "disjoint aliases keep independent generations" {
    var manager = Manager{};
    defer manager.deinit(std.testing.allocator);
    const writer = try manager.register(
        std.testing.allocator,
        .storage_image,
        .{ .address = 0x1000, .size = 0x1000 },
        test_signature,
    );
    const distant = try manager.register(
        std.testing.allocator,
        .sampled_image,
        .{ .address = 0x3000, .size = 0x1000 },
        test_signature,
    );
    _ = manager.markWrite(writer);
    try std.testing.expectEqual(@as(u64, 0), manager.generationForToken(distant));
}

test "compatibility requires the same range and storage signature" {
    var manager = Manager{};
    defer manager.deinit(std.testing.allocator);
    const token = try manager.register(
        std.testing.allocator,
        .color_target,
        .{ .address = 0x5000, .size = 0x4000 },
        test_signature,
    );
    try std.testing.expect(manager.compatibleAlias(
        token,
        .{ .address = 0x5000, .size = 0x4000 },
        test_signature,
    ));
    var other = test_signature;
    other.format = 44;
    try std.testing.expect(!manager.compatibleAlias(
        token,
        .{ .address = 0x5000, .size = 0x4000 },
        other,
    ));
    manager.unregister(token);
    try std.testing.expect(manager.entry(token) == null);
}

test "canonical writer produces a direct resolve for compatible storage" {
    var manager = Manager{};
    defer manager.deinit(std.testing.allocator);
    const color = try manager.register(
        std.testing.allocator,
        .color_target,
        .{ .address = 0x9000, .size = 0x4000 },
        test_signature,
    );
    const sampled = try manager.register(
        std.testing.allocator,
        .sampled_image,
        .{ .address = 0x9000, .size = 0x4000 },
        test_signature,
    );
    _ = manager.markWrite(color);
    const plan = manager.resolve(sampled).?;
    try std.testing.expectEqual(color, plan.source);
    try std.testing.expect(plan.direct);
    try std.testing.expect(manager.markSynchronized(sampled));
    try std.testing.expect(manager.resolve(sampled) == null);
}

test "reinterpretation resolves through guest canonical memory" {
    var manager = Manager{};
    defer manager.deinit(std.testing.allocator);
    const writer = try manager.register(
        std.testing.allocator,
        .storage_image,
        .{ .address = 0xa000, .size = 0x4000 },
        test_signature,
    );
    var reinterpreted = test_signature;
    reinterpreted.format = 44;
    const sampled = try manager.register(
        std.testing.allocator,
        .sampled_image,
        .{ .address = 0xa000, .size = 0x4000 },
        reinterpreted,
    );
    _ = manager.markWrite(writer);
    try std.testing.expect(!manager.resolve(sampled).?.direct);
    manager.publishGuest(.{ .address = 0xa000, .size = 0x4000 });
    try std.testing.expectEqual(@as(Token, 0), manager.resolve(sampled).?.source);
}

test "disabled canonical authority retains compatibility flush semantics" {
    var manager = Manager{ .canonical_authority_enabled = false };
    defer manager.deinit(std.testing.allocator);
    const writer = try manager.register(
        std.testing.allocator,
        .color_target,
        .{ .address = 0xb000, .size = 0x4000 },
        test_signature,
    );
    const sampled = try manager.register(
        std.testing.allocator,
        .sampled_image,
        .{ .address = 0xb000, .size = 0x4000 },
        test_signature,
    );
    _ = manager.markWrite(writer);
    try std.testing.expectEqual(
        @as(Token, 0),
        manager.authorityForRange(.{ .address = 0xb000, .size = 0x4000 }),
    );
    const plan = manager.resolve(sampled).?;
    try std.testing.expectEqual(@as(Token, 0), plan.source);
    try std.testing.expect(!plan.direct);
}

test "disabled manager preserves inert registration tokens" {
    var manager = Manager{ .enabled = false };
    defer manager.deinit(std.testing.allocator);
    const token = try manager.register(
        std.testing.allocator,
        .sampled_image,
        .{ .address = 0xc000, .size = 0x4000 },
        test_signature,
    );
    try std.testing.expect(token != 0);
    try std.testing.expectEqual(@as(u64, 0), manager.markWrite(token));
    try std.testing.expectEqual(@as(u64, 0), manager.generationForToken(token));
    try std.testing.expect(manager.resolve(token) == null);
    manager.unregister(token);
}
