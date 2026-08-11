// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The guest modules a process has loaded.
//!
//! A title does not only depend on modules through its dynamic tables. It also
//! loads some of them itself, by path, at the point it needs them — and then
//! uses the returned handle to look symbols up. The loader has already mapped
//! and relocated every module adjacent to the executable, so answering these
//! requests is a matter of naming what is already there rather than loading
//! anything new.
//!
//! Registered by the runtime once loading finishes; nothing here owns memory.

const std = @import("std");
const abi = @import("abi.zig");

/// Handle of the main executable. Titles treat this value as the process
/// image and never expect it to be handed out for a library.
pub const executable_handle: i32 = 0;

pub const Module = struct {
    handle: i32,
    /// Path relative to the title's root, in host form.
    path: []const u8,
    load_bias: u64,
    start: u64,
    end: u64,
    /// Registration id of the exports owned by this mapped image. Zero means
    /// the image publishes no dynamic symbols.
    export_module_id: u64 = 0,
    /// Entry points held until sceKernelLoadStartModule supplies the plug-in's
    /// actual argument block.
    init_functions: []const u64 = &.{},
    deferred_start: bool = false,
    start_state: std.atomic.Value(u8) = .init(0),

    pub fn contains(self: Module, address: u64) bool {
        return address >= self.start and address < self.end;
    }

    /// Starts a deferred native module in the calling guest thread. A direct
    /// System V call is intentional: LoadStartModule is already executing
    /// inside the dispatcher's protected guest boundary, so recursively
    /// entering the dispatcher would reject the active execution.
    pub fn startDeferred(self: *Module, args_size: u64, args: u64) i32 {
        if (!self.deferred_start) return 0;
        if (self.start_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return 0;
        defer self.start_state.store(2, .release);

        const Entry = *const fn (u64, u64, u64) callconv(abi.guest) u64;
        var result: u64 = 0;
        for (self.init_functions) |address| {
            if (address == 0) continue;
            const entry: Entry = @ptrFromInt(address);
            result = entry(args_size, args, 0);
        }
        return @bitCast(@as(u32, @truncate(result)));
    }
};

var empty_modules: [0]Module = .{};
var modules: []Module = &empty_modules;
pub const ResolveExportFn = *const fn (*anyopaque, u64, []const u8) ?u64;
var export_resolver_context: ?*anyopaque = null;
var export_resolver: ?ResolveExportFn = null;

pub fn attach(value: []Module) void {
    modules = value;
}

pub fn attachExportResolver(context: *anyopaque, resolver: ResolveExportFn) void {
    export_resolver_context = context;
    export_resolver = resolver;
}

pub fn detach() void {
    modules = &empty_modules;
    export_resolver_context = null;
    export_resolver = null;
}

pub fn count() usize {
    return modules.len;
}

pub fn findByHandle(handle: i32) ?*Module {
    for (modules) |*module| {
        if (module.handle == handle) return module;
    }
    return null;
}

pub fn findByAddress(address: u64) ?*Module {
    for (modules) |*module| {
        if (module.contains(address)) return module;
    }
    return null;
}

pub fn resolveExport(handle: i32, name: []const u8) ?u64 {
    const module = findByHandle(handle) orelse return null;
    if (module.export_module_id == 0) return null;
    const resolver = export_resolver orelse return null;
    const context = export_resolver_context orelse return null;
    return resolver(context, module.export_module_id, name);
}

/// Mount points a title uses to name its own files.
///
/// The executable and its modules live under `/app0`; the rest appear when
/// additional content is mounted. Only the prefix is stripped — what follows is
/// the path relative to the title root, which is how the loader knows it.
const mount_points = [_][]const u8{ "/app0/", "/hostapp/", "/host/" };

fn stripMount(path: []const u8) []const u8 {
    for (mount_points) |mount| {
        if (path.len >= mount.len and std.ascii.eqlIgnoreCase(path[0..mount.len], mount)) {
            return path[mount.len..];
        }
    }
    // A bare relative path is already in the right form.
    return std.mem.trimStart(u8, path, "/");
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Compares two paths ignoring separator style and case.
///
/// Case has to be ignored because titles do not spell their own file names
/// consistently: this one asks for `Il2CppUserAssemblies.prx` while shipping
/// `Il2cppUserAssemblies.prx`. Matching exactly would reject a module the title
/// itself installed.
fn pathsEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (isSeparator(a) and isSeparator(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, index| {
        if (isSeparator(c)) start = index + 1;
    }
    return path[start..];
}

/// Resolves a path the guest supplied to a loaded module.
///
/// The relative path is tried first so that two modules sharing a file name
/// stay distinguishable; a base-name match is the fallback for titles that
/// name a module without its directory.
pub fn findByPath(guest_path: []const u8) ?*Module {
    if (guest_path.len == 0) return null;
    const wanted = stripMount(guest_path);
    if (wanted.len == 0) return null;

    for (modules) |*module| {
        if (pathsEqual(module.path, wanted)) return module;
    }

    const wanted_base = baseName(wanted);
    for (modules) |*module| {
        if (pathsEqual(baseName(module.path), wanted_base)) return module;
    }
    return null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

var test_start_calls: usize = 0;
var test_start_args: [3]u64 = .{ 0, 0, 0 };

fn testStartEntry(args_size: u64, args: u64, reserved: u64) callconv(abi.guest) u64 {
    test_start_calls += 1;
    test_start_args = .{ args_size, args, reserved };
    return 0xffff_ffff_89ab_cdef;
}

var sample = [_]Module{
    .{
        .handle = executable_handle,
        .path = "eboot.bin",
        .load_bias = 0x40000,
        .start = 0x40000,
        .end = 0x80000,
    },
    .{
        .handle = 1,
        .path = "Media\\Modules\\Il2cppUserAssemblies.prx",
        .load_bias = 0x800000000,
        .start = 0x800000000,
        .end = 0x801000000,
    },
    .{
        .handle = 2,
        .path = "Media\\Modules\\PS5Util.prx",
        .load_bias = 0x8016e8000,
        .start = 0x8016e8000,
        .end = 0x8016f0000,
    },
};

test "a mounted guest path resolves to a loaded module" {
    attach(&sample);
    defer detach();

    const found = findByPath("/app0/Media/Modules/PS5Util.prx") orelse
        return error.TestExpectedModule;
    try testing.expectEqual(@as(i32, 2), found.handle);
}

test "the file name case a title uses need not match the file" {
    attach(&sample);
    defer detach();

    // The title asks for this spelling while shipping "Il2cpp...". Rejecting it
    // would refuse a module the title installed itself.
    const found = findByPath("/app0/Media/Modules/Il2CppUserAssemblies.prx") orelse
        return error.TestExpectedModule;
    try testing.expectEqual(@as(i32, 1), found.handle);
}

test "separator style is irrelevant" {
    attach(&sample);
    defer detach();

    try testing.expect(findByPath("/app0/Media\\Modules\\PS5Util.prx") != null);
    try testing.expect(findByPath("Media/Modules/PS5Util.prx") != null);
}

test "a bare file name still resolves" {
    attach(&sample);
    defer detach();

    const found = findByPath("PS5Util.prx") orelse return error.TestExpectedModule;
    try testing.expectEqual(@as(i32, 2), found.handle);
}

test "the full path wins over a matching base name" {
    var ambiguous = [_]Module{
        .{ .handle = 1, .path = "a\\shared.prx", .load_bias = 0, .start = 0, .end = 1 },
        .{ .handle = 2, .path = "b\\shared.prx", .load_bias = 0, .start = 1, .end = 2 },
    };
    attach(&ambiguous);
    defer detach();

    try testing.expectEqual(@as(i32, 2), findByPath("/app0/b/shared.prx").?.handle);
    try testing.expectEqual(@as(i32, 1), findByPath("/app0/a/shared.prx").?.handle);
}

test "an unknown path resolves to nothing" {
    attach(&sample);
    defer detach();

    try testing.expect(findByPath("/app0/Media/Modules/Missing.prx") == null);
    try testing.expect(findByPath("") == null);
    try testing.expect(findByPath("/app0/") == null);
}

test "handles and addresses resolve" {
    attach(&sample);
    defer detach();

    try testing.expectEqualStrings("eboot.bin", findByHandle(executable_handle).?.path);
    try testing.expect(findByHandle(99) == null);

    try testing.expectEqual(@as(i32, 2), findByAddress(0x8016e8100).?.handle);
    try testing.expect(findByAddress(0) == null);
}

test "a deferred module starts once with the loader argument block" {
    test_start_calls = 0;
    test_start_args = .{ 0, 0, 0 };
    const initializers = [_]u64{@intFromPtr(&testStartEntry)};
    var module = Module{
        .handle = 7,
        .path = "plugin.prx",
        .load_bias = 0x1000,
        .start = 0x1000,
        .end = 0x2000,
        .init_functions = &initializers,
        .deferred_start = true,
    };

    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x89ab_cdef))), module.startDeferred(0x34, 0x1234));
    try testing.expectEqual(@as(usize, 1), test_start_calls);
    try testing.expectEqual([3]u64{ 0x34, 0x1234, 0 }, test_start_args);
    try testing.expectEqual(@as(i32, 0), module.startDeferred(1, 2));
    try testing.expectEqual(@as(usize, 1), test_start_calls);
}
