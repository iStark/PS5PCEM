// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The registry the dynamic linker resolves guest imports against.
//!
//! A guest import is not just an identifier. The same identifier can be exported
//! by several libraries, so a lookup is keyed on the identifier together with
//! the library and module it was requested from, plus their versions.
//!
//! Registration goes through readable names: `nid.fromName` derives the
//! identifier, and an optional expected identifier can be supplied so that a
//! misspelled name is caught at registration time rather than showing up later
//! as an unresolved import.

const std = @import("std");
const nid = @import("nid.zig");
const abi = @import("abi.zig");

pub const Error = error{
    /// A name did not hash to the identifier the caller asserted.
    IdentifierMismatch,
} || std.mem.Allocator.Error;

pub const SymbolType = enum {
    function,
    object,
    tls_module,
    no_type,
};

/// The library an export belongs to, as named in the guest's dynamic tables.
pub const Library = struct {
    name: []const u8,
    version: i32 = 1,
};

/// The module a library is part of. Several libraries can share a module.
pub const Module = struct {
    name: []const u8,
    version_major: i32 = 1,
    version_minor: i32 = 1,
};

/// Everything needed to identify one export.
pub const Key = struct {
    id: nid.Encoded,
    library: Library,
    module: Module,
    type: SymbolType,

    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, &a.id, &b.id) and
            a.type == b.type and
            a.library.version == b.library.version and
            a.module.version_major == b.module.version_major and
            a.module.version_minor == b.module.version_minor and
            std.mem.eql(u8, a.library.name, b.library.name) and
            std.mem.eql(u8, a.module.name, b.module.name);
    }
};

/// A registered export.
pub const Symbol = struct {
    key: Key,
    /// Readable name, retained for logs and for dumping the resolved table.
    name: []const u8,
    /// Address of the implementation, in host address space.
    address: u64,
};

/// Describes one export before it is registered.
pub const Export = struct {
    /// Firmware export name, e.g. "sceKernelAllocateDirectMemory".
    name: []const u8,
    /// Implementation. Must be declared `callconv(abi.guest)`.
    function: abi.RawEntryPoint,
    /// Optional assertion that `name` hashes to this identifier. Supplying it
    /// turns a typo into a registration failure.
    expect_id: ?[]const u8 = null,
    type: SymbolType = .function,
};

pub const Database = struct {
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn deinit(self: *Database, gpa: std.mem.Allocator) void {
        self.symbols.deinit(gpa);
    }

    /// Registers one export.
    pub fn add(
        self: *Database,
        gpa: std.mem.Allocator,
        library: Library,
        module: Module,
        e: Export,
    ) Error!void {
        const id = nid.fromName(e.name);

        if (e.expect_id) |expected| {
            if (!std.mem.eql(u8, &id, expected)) return Error.IdentifierMismatch;
        }

        try self.symbols.append(gpa, .{
            .key = .{ .id = id, .library = library, .module = module, .type = e.type },
            .name = e.name,
            .address = @intFromPtr(e.function),
        });
    }

    /// Registers a whole library at once.
    ///
    /// This is how a firmware module declares what it provides; the export table
    /// stays a plain data declaration next to the implementations.
    pub fn addLibrary(
        self: *Database,
        gpa: std.mem.Allocator,
        library: Library,
        module: Module,
        exports: []const Export,
    ) Error!void {
        try self.symbols.ensureUnusedCapacity(gpa, exports.len);
        for (exports) |e| {
            try self.add(gpa, library, module, e);
        }
    }

    /// Exact lookup, as the dynamic linker performs it when the guest supplies
    /// full library and module metadata.
    pub fn find(self: *const Database, key: Key) ?*const Symbol {
        for (self.symbols.items) |*s| {
            if (s.key.eql(key)) return s;
        }
        return null;
    }

    /// Fallback lookup used when a guest import carries no usable library or
    /// module metadata. Ambiguous by construction — it returns the first match —
    /// so it is only correct as a last resort.
    pub fn findById(self: *const Database, id: []const u8, symbol_type: SymbolType) ?*const Symbol {
        for (self.symbols.items) |*s| {
            if (s.key.type == symbol_type and std.mem.eql(u8, &s.key.id, id)) return s;
        }
        return null;
    }

    /// Convenience lookup by readable name, for tests and diagnostics.
    pub fn findByName(self: *const Database, name: []const u8, symbol_type: SymbolType) ?*const Symbol {
        return self.findById(&nid.fromName(name), symbol_type);
    }

    pub fn count(self: *const Database) usize {
        return self.symbols.items.len;
    }
};

const testing = std.testing;

const test_library = Library{ .name = "libkernel", .version = 1 };
const test_module = Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

fn stubA() callconv(abi.guest) void {}
fn stubB() callconv(abi.guest) void {}

test "an export can be found by its full key" {
    var db = Database{};
    defer db.deinit(testing.allocator);

    try db.add(testing.allocator, test_library, test_module, .{
        .name = "sceKernelAllocateDirectMemory",
        .function = abi.erase(&stubA),
        .expect_id = "rTXw65xmLIA",
    });

    const key = Key{
        .id = nid.fromName("sceKernelAllocateDirectMemory"),
        .library = test_library,
        .module = test_module,
        .type = .function,
    };

    const found = db.find(key) orelse return error.TestExpectedSymbol;
    try testing.expectEqualStrings("sceKernelAllocateDirectMemory", found.name);
    try testing.expectEqual(@intFromPtr(abi.erase(&stubA)), found.address);
}

test "a mismatched identifier assertion is rejected" {
    var db = Database{};
    defer db.deinit(testing.allocator);

    try testing.expectError(Error.IdentifierMismatch, db.add(
        testing.allocator,
        test_library,
        test_module,
        .{
            .name = "sceKernelAllocateDirectMemory",
            .function = abi.erase(&stubA),
            // Belongs to sceKernelReleaseDirectMemory.
            .expect_id = "MBuItvba6z8",
        },
    ));
    try testing.expectEqual(@as(usize, 0), db.count());
}

test "lookups respect library and module identity" {
    var db = Database{};
    defer db.deinit(testing.allocator);

    try db.add(testing.allocator, test_library, test_module, .{
        .name = "sceKernelAllocateDirectMemory",
        .function = abi.erase(&stubA),
    });

    // Same identifier, different library: must not resolve.
    const other = Key{
        .id = nid.fromName("sceKernelAllocateDirectMemory"),
        .library = .{ .name = "libSceGnmDriver", .version = 1 },
        .module = test_module,
        .type = .function,
    };
    try testing.expect(db.find(other) == null);

    // Same library, different version: must not resolve either.
    const wrong_version = Key{
        .id = nid.fromName("sceKernelAllocateDirectMemory"),
        .library = .{ .name = "libkernel", .version = 2 },
        .module = test_module,
        .type = .function,
    };
    try testing.expect(db.find(wrong_version) == null);
}

test "identifier fallback ignores library metadata but respects type" {
    var db = Database{};
    defer db.deinit(testing.allocator);

    try db.add(testing.allocator, test_library, test_module, .{
        .name = "sceKernelMapDirectMemory",
        .function = abi.erase(&stubB),
    });

    try testing.expect(db.findById("L-Q3LEjIbgA", .function) != null);
    // The same identifier as an object, which was never registered.
    try testing.expect(db.findById("L-Q3LEjIbgA", .object) == null);
}

test "a library registers as one declaration" {
    var db = Database{};
    defer db.deinit(testing.allocator);

    try db.addLibrary(testing.allocator, test_library, test_module, &.{
        .{ .name = "sceKernelAllocateDirectMemory", .function = abi.erase(&stubA) },
        .{ .name = "sceKernelReleaseDirectMemory", .function = abi.erase(&stubB) },
        .{ .name = "sceKernelMapDirectMemory", .function = abi.erase(&stubB) },
    });

    try testing.expectEqual(@as(usize, 3), db.count());
    try testing.expect(db.findByName("sceKernelReleaseDirectMemory", .function) != null);
    try testing.expect(db.findByName("sceKernelGetDirectMemorySize", .function) == null);
}
