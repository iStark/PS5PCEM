// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deliberately offline networking, SSL, HTTP, and NP Web API services.
//!
//! The guest receives coherent local handles and can run the normal
//! init/configure/cleanup paths, but no call in this module opens a host socket
//! or performs DNS/HTTP I/O. Operations which require a peer fail with the
//! corresponding guest-network error instead of ENOSYS or false success.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const net_error_bad_file_descriptor: i32 = @bitCast(@as(u32, 0x8041_0109));
const net_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8041_0116));
const net_error_network_down: i32 = @bitCast(@as(u32, 0x8041_0132));

const ssl_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8095_F001));
const ssl_error_invalid_id: i32 = @bitCast(@as(u32, 0x8095_F006));
const ssl_error_out_of_size: i32 = @bitCast(@as(u32, 0x8095_F008));
const ssl_error_not_found: i32 = @bitCast(@as(u32, 0x8095_F00A));

const http_error_invalid_value: i32 = @bitCast(@as(u32, 0x8043_11FE));
const http_error_out_of_memory: i32 = @bitCast(@as(u32, 0x8043_1022));
const http_error_invalid_url: i32 = @bitCast(@as(u32, 0x8043_3060));
const http_error_invalid_id: i32 = @bitCast(@as(u32, 0x8043_1100));

const http2_error_invalid_id: i32 = @bitCast(@as(u32, 0x817B_1100));
const http2_error_before_send: i32 = @bitCast(@as(u32, 0x817B_1065));
const http2_error_timeout: i32 = @bitCast(@as(u32, 0x817B_1068));
const http2_error_null_pointer: i32 = @bitCast(@as(u32, 0x817B_1225));

const web_api_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8055_3402));
const web_api_error_request_not_found: i32 = @bitCast(@as(u32, 0x8055_3406));
const web_api_error_not_signed_in: i32 = @bitCast(@as(u32, 0x8055_3407));

const HandleKind = enum(u8) {
    none,
    net_pool,
    resolver,
    socket,
    epoll,
    ssl_context,
    http_context,
    http2_context,
    http2_template,
    http2_cookie_box,
    http2_request,
    web_api_context,
    web_api_user,
    web_api_request,
};

const Handle = struct {
    kind: HandleKind = .none,
    parent: i32 = 0,
    send_result: i32 = http2_error_before_send,
};

const maximum_handles = 256;
const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

var handle_mutex: Lock = .{};
var handles: [maximum_handles]Handle = [_]Handle{.{}} ** maximum_handles;
threadlocal var net_errno: i32 = 0;

pub fn reset() void {
    handle_mutex.lock();
    defer handle_mutex.unlock();
    handles = [_]Handle{.{}} ** maximum_handles;
    net_errno = 0;
}

fn allocateHandle(kind: HandleKind, parent: i32) ?i32 {
    handle_mutex.lock();
    defer handle_mutex.unlock();
    for (&handles, 0..) |*handle, index| {
        if (handle.kind != .none) continue;
        handle.* = .{ .kind = kind, .parent = parent };
        return @intCast(index + 1);
    }
    return null;
}

fn handleIndex(id: i32) ?usize {
    if (id <= 0 or id > maximum_handles) return null;
    return @intCast(id - 1);
}

fn isHandle(id: i32, kind: HandleKind) bool {
    const index = handleIndex(id) orelse return false;
    handle_mutex.lock();
    defer handle_mutex.unlock();
    return handles[index].kind == kind;
}

fn isHttp2OptionTarget(id: i32) bool {
    const index = handleIndex(id) orelse return false;
    handle_mutex.lock();
    defer handle_mutex.unlock();
    return switch (handles[index].kind) {
        .http2_template, .http2_request => true,
        else => false,
    };
}

fn releaseHandle(id: i32, kind: HandleKind) bool {
    const index = handleIndex(id) orelse return false;
    handle_mutex.lock();
    defer handle_mutex.unlock();
    if (handles[index].kind != kind) return false;
    handles[index] = .{};
    return true;
}

fn releaseTree(id: i32, kind: HandleKind) bool {
    const index = handleIndex(id) orelse return false;
    handle_mutex.lock();
    defer handle_mutex.unlock();
    if (handles[index].kind != kind) return false;

    var removed = [_]bool{false} ** maximum_handles;
    removed[index] = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (handles, 0..) |handle, child_index| {
            if (handle.kind == .none or removed[child_index]) continue;
            const parent_index = handleIndex(handle.parent) orelse continue;
            if (removed[parent_index]) {
                removed[child_index] = true;
                changed = true;
            }
        }
    }
    for (&handles, 0..) |*handle, removed_index| {
        if (removed[removed_index]) handle.* = .{};
    }
    return true;
}

fn setRequestResult(id: i32, result: i32) bool {
    const index = handleIndex(id) orelse return false;
    handle_mutex.lock();
    defer handle_mutex.unlock();
    if (handles[index].kind != .http2_request) return false;
    handles[index].send_result = result;
    return true;
}

fn requestResult(id: i32) ?i32 {
    const index = handleIndex(id) orelse return null;
    handle_mutex.lock();
    defer handle_mutex.unlock();
    if (handles[index].kind != .http2_request) return null;
    return handles[index].send_result;
}

fn setNetError(value: i32) i32 {
    net_errno = value;
    return value;
}

// libSceNet -----------------------------------------------------------------

fn netInit() callconv(abi.guest) i32 {
    return errno.ok;
}

fn netTerm() callconv(abi.guest) i32 {
    return errno.ok;
}

fn netErrnoLoc() callconv(abi.guest) *i32 {
    return &net_errno;
}

fn netPoolCreate(_: ?[*:0]const u8, size: i32, _: i32) callconv(abi.guest) i32 {
    if (size <= 0) return setNetError(net_error_invalid_argument);
    return allocateHandle(.net_pool, 0) orelse setNetError(net_error_invalid_argument);
}

fn netPoolDestroy(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .net_pool)) errno.ok else setNetError(net_error_invalid_argument);
}

fn netResolverCreate(_: ?[*:0]const u8, pool_id: i32, _: i32) callconv(abi.guest) i32 {
    if (!isHandle(pool_id, .net_pool)) return setNetError(net_error_invalid_argument);
    return allocateHandle(.resolver, pool_id) orelse setNetError(net_error_invalid_argument);
}

fn netResolverDestroy(id: i32) callconv(abi.guest) i32 {
    return if (releaseHandle(id, .resolver)) errno.ok else setNetError(net_error_invalid_argument);
}

fn netResolverStartNtoa(
    id: i32,
    _: ?[*:0]const u8,
    _: ?*anyopaque,
    _: i32,
    _: i32,
    _: i32,
) callconv(abi.guest) i32 {
    if (!isHandle(id, .resolver)) return setNetError(net_error_invalid_argument);
    return setNetError(net_error_network_down);
}

fn netResolverGetError(id: i32, output: ?*i32) callconv(abi.guest) i32 {
    if (!isHandle(id, .resolver)) return setNetError(net_error_bad_file_descriptor);
    const status = output orelse return setNetError(net_error_invalid_argument);
    status.* = net_error_network_down;
    return errno.ok;
}

fn netSocket(_: ?[*:0]const u8, _: i32, _: i32, _: i32) callconv(abi.guest) i32 {
    return allocateHandle(.socket, 0) orelse setNetError(net_error_invalid_argument);
}

fn netSocketClose(id: i32) callconv(abi.guest) i32 {
    return if (releaseHandle(id, .socket)) errno.ok else setNetError(net_error_bad_file_descriptor);
}

fn netSocketAcceptsLocalState(id: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (isHandle(id, .socket)) errno.ok else setNetError(net_error_bad_file_descriptor);
}

fn netSocketNeedsPeer(id: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (!isHandle(id, .socket)) return setNetError(net_error_bad_file_descriptor);
    return setNetError(net_error_network_down);
}

fn netGetSockName(id: i32, address: ?[*]u8, address_length: ?*u32) callconv(abi.guest) i32 {
    if (!isHandle(id, .socket)) return setNetError(net_error_bad_file_descriptor);
    const length = address_length orelse return setNetError(net_error_invalid_argument);
    const output = address orelse return setNetError(net_error_invalid_argument);
    const written: usize = @min(length.*, 16);
    @memset(output[0..written], 0);
    if (written >= 2) {
        output[0] = 16;
        output[1] = 2; // ORBIS_NET_AF_INET
    }
    length.* = 16;
    return errno.ok;
}

fn netGetSockOpt(
    id: i32,
    _: i32,
    _: i32,
    value: ?*u32,
    value_length: ?*u32,
) callconv(abi.guest) i32 {
    if (!isHandle(id, .socket)) return setNetError(net_error_bad_file_descriptor);
    const length = value_length orelse return setNetError(net_error_invalid_argument);
    const output = value orelse return setNetError(net_error_invalid_argument);
    if (length.* < @sizeOf(u32)) return setNetError(net_error_invalid_argument);
    output.* = 0;
    length.* = @sizeOf(u32);
    return errno.ok;
}

fn netEpollCreate(_: ?[*:0]const u8, _: i32) callconv(abi.guest) i32 {
    return allocateHandle(.epoll, 0) orelse setNetError(net_error_invalid_argument);
}

fn netEpollControl(id: i32, _: i32, _: i32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    return if (isHandle(id, .epoll)) errno.ok else setNetError(net_error_bad_file_descriptor);
}

fn netEpollWait(id: i32, _: ?*anyopaque, max_events: i32, _: i32) callconv(abi.guest) i32 {
    if (!isHandle(id, .epoll)) return setNetError(net_error_bad_file_descriptor);
    if (max_events <= 0) return setNetError(net_error_invalid_argument);
    return 0;
}

fn netEpollDestroy(id: i32) callconv(abi.guest) i32 {
    return if (releaseHandle(id, .epoll)) errno.ok else setNetError(net_error_bad_file_descriptor);
}

fn netHtons(value: u16) callconv(abi.guest) u16 {
    return @byteSwap(value);
}

fn netInetPton(family: i32, text: ?[*:0]const u8, output: ?[*]u8) callconv(abi.guest) i32 {
    if (family != 2) return setNetError(net_error_invalid_argument);
    const source = text orelse return setNetError(net_error_invalid_argument);
    const address = output orelse return setNetError(net_error_invalid_argument);
    var parts = std.mem.splitScalar(u8, std.mem.span(source), '.');
    var index: usize = 0;
    while (parts.next()) |part| {
        if (index == 4 or part.len == 0) return 0;
        address[index] = std.fmt.parseInt(u8, part, 10) catch return 0;
        index += 1;
    }
    return if (index == 4) 1 else 0;
}

const net_exports = [_]symbols.Export{
    .{ .name = "sceNetInit", .function = trace.wrap("sceNetInit", &netInit), .expect_id = "Nlev7Lg8k3A" },
    .{ .name = "sceNetTerm", .function = trace.wrap("sceNetTerm", &netTerm), .expect_id = "cTGkc6-TBlI" },
    .{ .name = "sceNetErrnoLoc", .function = trace.wrap("sceNetErrnoLoc", &netErrnoLoc), .expect_id = "HQOwnfMGipQ" },
    .{ .name = "sceNetPoolCreate", .function = trace.wrap("sceNetPoolCreate", &netPoolCreate), .expect_id = "dgJBaeJnGpo" },
    .{ .name = "sceNetPoolDestroy", .function = trace.wrap("sceNetPoolDestroy", &netPoolDestroy), .expect_id = "K7RlrTkI-mw" },
    .{ .name = "sceNetResolverCreate", .function = trace.wrap("sceNetResolverCreate", &netResolverCreate), .expect_id = "C4UgDHHPvdw" },
    .{ .name = "sceNetResolverDestroy", .function = trace.wrap("sceNetResolverDestroy", &netResolverDestroy), .expect_id = "kJlYH5uMAWI" },
    .{ .name = "sceNetResolverStartNtoa", .function = trace.wrap("sceNetResolverStartNtoa", &netResolverStartNtoa), .expect_id = "Nd91WaWmG2w" },
    .{ .name = "sceNetResolverGetError", .function = trace.wrap("sceNetResolverGetError", &netResolverGetError), .expect_id = "J5i3hiLJMPk" },
    .{ .name = "sceNetSocket", .function = trace.wrap("sceNetSocket", &netSocket), .expect_id = "Q4qBuN-c0ZM" },
    .{ .name = "sceNetSocketClose", .function = trace.wrap("sceNetSocketClose", &netSocketClose), .expect_id = "45ggEzakPJQ" },
    .{ .name = "sceNetSetsockopt", .function = trace.wrap("sceNetSetsockopt", &netSocketAcceptsLocalState), .expect_id = "2mKX2Spso7I" },
    .{ .name = "sceNetBind", .function = trace.wrap("sceNetBind", &netSocketAcceptsLocalState), .expect_id = "bErx49PgxyY" },
    .{ .name = "sceNetListen", .function = trace.wrap("sceNetListen", &netSocketAcceptsLocalState), .expect_id = "kOj1HiAGE54" },
    .{ .name = "sceNetConnect", .function = trace.wrap("sceNetConnect", &netSocketNeedsPeer), .expect_id = "OXXX4mUk3uk" },
    .{ .name = "sceNetAccept", .function = trace.wrap("sceNetAccept", &netSocketNeedsPeer), .expect_id = "PIWqhn9oSxc" },
    .{ .name = "sceNetSend", .function = trace.wrap("sceNetSend", &netSocketNeedsPeer), .expect_id = "beRjXBn-z+o" },
    .{ .name = "sceNetSendto", .function = trace.wrap("sceNetSendto", &netSocketNeedsPeer), .expect_id = "gvD1greCu0A" },
    .{ .name = "sceNetRecv", .function = trace.wrap("sceNetRecv", &netSocketNeedsPeer), .expect_id = "9wO9XrMsNhc" },
    .{ .name = "sceNetRecvfrom", .function = trace.wrap("sceNetRecvfrom", &netSocketNeedsPeer), .expect_id = "304ooNZxWDY" },
    .{ .name = "sceNetGetsockname", .function = trace.wrap("sceNetGetsockname", &netGetSockName), .expect_id = "hoOAofhhRvE" },
    .{ .name = "sceNetGetsockopt", .function = trace.wrap("sceNetGetsockopt", &netGetSockOpt), .expect_id = "xphrZusl78E" },
    .{ .name = "sceNetEpollCreate", .function = trace.wrap("sceNetEpollCreate", &netEpollCreate), .expect_id = "SF47kB2MNTo" },
    .{ .name = "sceNetEpollControl", .function = trace.wrap("sceNetEpollControl", &netEpollControl), .expect_id = "ZVw46bsasAk" },
    .{ .name = "sceNetEpollWait", .function = trace.wrap("sceNetEpollWait", &netEpollWait), .expect_id = "drjIbDbA7UQ" },
    .{ .name = "sceNetEpollDestroy", .function = trace.wrap("sceNetEpollDestroy", &netEpollDestroy), .expect_id = "Inp1lfL+Jdw" },
    .{ .name = "sceNetHtons", .function = trace.wrap("sceNetHtons", &netHtons), .expect_id = "iWQWrwiSt8A" },
    .{ .name = "sceNetInetPton", .function = trace.wrap("sceNetInetPton", &netInetPton), .expect_id = "8Kcp5d-q1Uo" },
};

// libSceSsl -----------------------------------------------------------------

const SslCaCerts = extern struct {
    cert_data: ?*anyopaque = null,
    cert_data_num: usize = 0,
    pool: ?*anyopaque = null,
};

fn sslInit(pool_size: u64) callconv(abi.guest) i32 {
    if (pool_size == 0) return ssl_error_out_of_size;
    return allocateHandle(.ssl_context, 0) orelse ssl_error_out_of_size;
}

fn sslTerm(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .ssl_context)) errno.ok else ssl_error_invalid_id;
}

fn sslGetCaCerts(id: i32, output: ?*SslCaCerts) callconv(abi.guest) i32 {
    const certs = output orelse return ssl_error_invalid_argument;
    certs.* = .{};
    if (!isHandle(id, .ssl_context)) return ssl_error_invalid_id;
    return ssl_error_not_found;
}

fn sslFreeCaCerts(id: i32, output: ?*SslCaCerts) callconv(abi.guest) i32 {
    const certs = output orelse return ssl_error_invalid_argument;
    certs.* = .{};
    return if (isHandle(id, .ssl_context)) errno.ok else ssl_error_invalid_id;
}

fn sslUnavailable(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return ssl_error_not_found;
}

const ssl_exports = [_]symbols.Export{
    .{ .name = "sceSslInit", .function = trace.wrap("sceSslInit", &sslInit), .expect_id = "hdpVEUDFW3s" },
    .{ .name = "sceSslTerm", .function = trace.wrap("sceSslTerm", &sslTerm), .expect_id = "0K1yQ6Lv-Yc" },
    .{ .name = "sceSslGetCaCerts", .function = trace.wrap("sceSslGetCaCerts", &sslGetCaCerts), .expect_id = "TDfQqO-gMbY" },
    .{ .name = "sceSslFreeCaCerts", .function = trace.wrap("sceSslFreeCaCerts", &sslFreeCaCerts), .expect_id = "qIvLs0gYxi0" },
    .{ .name = "sceSslGetMemoryPoolStats", .function = trace.wrap("sceSslGetMemoryPoolStats", &sslUnavailable), .expect_id = "-PoIzr3PEk0" },
    .{ .name = "sceSslGetNameEntryCount", .function = trace.wrap("sceSslGetNameEntryCount", &sslUnavailable), .expect_id = "R1ePzopYPYM" },
    .{ .name = "sceSslGetNameEntryInfo", .function = trace.wrap("sceSslGetNameEntryInfo", &sslUnavailable), .expect_id = "7RBSTKGrmDA" },
    .{ .name = "sceSslFreeSslCertName", .function = trace.wrap("sceSslFreeSslCertName", &sslUnavailable), .expect_id = "RwXD8grHZHM" },
    .{ .name = "sceSslGetIssuerName", .function = trace.wrap("sceSslGetIssuerName", &sslUnavailable), .expect_id = "7whYpYfHP74" },
    .{ .name = "sceSslGetSubjectName", .function = trace.wrap("sceSslGetSubjectName", &sslUnavailable), .expect_id = "dQReuBX9sD8" },
    .{ .name = "sceSslGetSerialNumber", .function = trace.wrap("sceSslGetSerialNumber", &sslUnavailable), .expect_id = "DOwXL+FQMEY" },
    .{ .name = "sceSslGetPem", .function = trace.wrap("sceSslGetPem", &sslUnavailable), .expect_id = "kLB5aGoUJXg" },
};

// libSceHttp URI parsing and lifecycle -------------------------------------

const HttpUriElement = extern struct {
    is_opaque: i32 = 0,
    padding: u32 = 0,
    scheme: ?[*]u8 = null,
    username: ?[*]u8 = null,
    password: ?[*]u8 = null,
    hostname: ?[*]u8 = null,
    path: ?[*]u8 = null,
    query: ?[*]u8 = null,
    fragment: ?[*]u8 = null,
    port: u16 = 0,
    reserved: [10]u8 = [_]u8{0} ** 10,
};

comptime {
    if (@sizeOf(HttpUriElement) != 80) @compileError("SceHttpUriElement ABI size mismatch");
}

fn httpInit(_: i32, _: i32, pool_size: usize) callconv(abi.guest) i32 {
    if (pool_size == 0) return http_error_invalid_value;
    return allocateHandle(.http_context, 0) orelse http_error_out_of_memory;
}

fn httpTerm(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .http_context)) errno.ok else http_error_invalid_id;
}

fn validScheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

fn copyUriPart(
    field: *?[*]u8,
    part: ?[]const u8,
    pool: [*]u8,
    cursor: *usize,
) void {
    const value = part orelse return;
    const start = cursor.*;
    @memcpy(pool[start .. start + value.len], value);
    pool[start + value.len] = 0;
    field.* = pool + start;
    cursor.* += value.len + 1;
}

fn httpUriParse(
    output: ?*HttpUriElement,
    source_z: ?[*:0]const u8,
    pool_optional: ?[*]u8,
    required: ?*usize,
    prepared: usize,
) callconv(abi.guest) i32 {
    const source_pointer = source_z orelse return http_error_invalid_url;
    if (output == null and pool_optional == null and required == null) return http_error_invalid_value;
    const source = std.mem.span(source_pointer);

    if (source.len == 0) {
        if (required) |value| value.* = 3;
        if (output) |element| element.* = .{ .is_opaque = 1 };
        if (output != null and pool_optional != null) {
            if (prepared != 0 and prepared < 3) return http_error_out_of_memory;
            const element = output.?;
            const pool = pool_optional.?;
            pool[0] = 0;
            pool[1] = 0;
            pool[2] = 0;
            element.scheme = pool;
            element.hostname = pool + 1;
            element.path = pool + 2;
        }
        return errno.ok;
    }

    const colon = std.mem.indexOfScalar(u8, source, ':') orelse return http_error_invalid_url;
    const scheme = source[0..colon];
    if (!validScheme(scheme)) return http_error_invalid_url;

    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var hostname: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var query: ?[]const u8 = null;
    var fragment: ?[]const u8 = null;
    var port: u16 = 0;
    var is_opaque = true;
    var cursor = colon + 1;

    if (cursor + 1 < source.len and source[cursor] == '/' and source[cursor + 1] == '/') {
        is_opaque = false;
        cursor += 2;
        const authority_start = cursor;
        while (cursor < source.len and source[cursor] != '/' and source[cursor] != '?' and source[cursor] != '#') : (cursor += 1) {}
        const authority = source[authority_start..cursor];
        var host = authority;
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            const user_info = authority[0..at];
            host = authority[at + 1 ..];
            if (std.mem.indexOfScalar(u8, user_info, ':')) |password_separator| {
                username = user_info[0..password_separator];
                password = user_info[password_separator + 1 ..];
            } else {
                username = user_info;
            }
        }

        if (host.len != 0 and host[0] == '[') {
            const close = std.mem.indexOfScalar(u8, host, ']') orelse return http_error_invalid_url;
            hostname = host[0 .. close + 1];
            if (close + 1 < host.len) {
                if (host[close + 1] != ':' or close + 2 == host.len) return http_error_invalid_url;
                port = std.fmt.parseInt(u16, host[close + 2 ..], 10) catch return http_error_invalid_url;
            }
        } else if (std.mem.lastIndexOfScalar(u8, host, ':')) |port_separator| {
            if (port_separator + 1 == host.len) return http_error_invalid_url;
            hostname = if (port_separator == 0) null else host[0..port_separator];
            port = std.fmt.parseInt(u16, host[port_separator + 1 ..], 10) catch return http_error_invalid_url;
        } else if (host.len != 0) {
            hostname = host;
        }
    }

    const path_start = cursor;
    while (cursor < source.len and source[cursor] != '?' and source[cursor] != '#') : (cursor += 1) {}
    if (cursor > path_start) path = source[path_start..cursor];
    if (cursor < source.len and source[cursor] == '?') {
        const query_start = cursor;
        while (cursor < source.len and source[cursor] != '#') : (cursor += 1) {}
        query = source[query_start..cursor];
    }
    if (cursor < source.len and source[cursor] == '#') fragment = source[cursor..];

    const parts = [_]?[]const u8{ scheme, username, password, hostname, path, query, fragment };
    var needed: usize = 0;
    for (parts) |part| if (part) |value| {
        needed += value.len + 1;
    };
    if (required) |value| value.* = needed;
    if (output) |element| element.* = .{ .is_opaque = @intFromBool(is_opaque), .port = port };

    if (output != null and pool_optional != null) {
        if (prepared != 0 and prepared < needed) return http_error_out_of_memory;
        const element = output.?;
        const pool = pool_optional.?;
        var pool_cursor: usize = 0;
        copyUriPart(&element.scheme, scheme, pool, &pool_cursor);
        copyUriPart(&element.username, username, pool, &pool_cursor);
        copyUriPart(&element.password, password, pool, &pool_cursor);
        copyUriPart(&element.hostname, hostname, pool, &pool_cursor);
        copyUriPart(&element.path, path, pool, &pool_cursor);
        copyUriPart(&element.query, query, pool, &pool_cursor);
        copyUriPart(&element.fragment, fragment, pool, &pool_cursor);
    }
    return errno.ok;
}

const http_exports = [_]symbols.Export{
    .{ .name = "sceHttpInit", .function = trace.wrap("sceHttpInit", &httpInit), .expect_id = "A9cVMUtEp4Y" },
    .{ .name = "sceHttpTerm", .function = trace.wrap("sceHttpTerm", &httpTerm), .expect_id = "Ik-KpLTlf7Q" },
    .{ .name = "sceHttpUriParse", .function = trace.wrap("sceHttpUriParse", &httpUriParse), .expect_id = "IWalAn-guFs" },
};

// libSceHttp2 ---------------------------------------------------------------

fn http2Init(_: i32, _: i32, pool_size: usize, maximum_requests: i32) callconv(abi.guest) i32 {
    if (pool_size == 0 or maximum_requests <= 0) return http2_error_null_pointer;
    return allocateHandle(.http2_context, 0) orelse http_error_out_of_memory;
}

fn http2Term(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .http2_context)) errno.ok else http2_error_invalid_id;
}

fn http2CreateTemplate(context_id: i32, _: ?[*:0]const u8, _: i32, _: i32) callconv(abi.guest) i32 {
    if (!isHandle(context_id, .http2_context)) return http2_error_invalid_id;
    return allocateHandle(.http2_template, context_id) orelse http_error_out_of_memory;
}

fn http2DeleteTemplate(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .http2_template)) errno.ok else http2_error_invalid_id;
}

fn http2CreateCookieBox(context_id: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (!isHandle(context_id, .http2_context)) return http2_error_invalid_id;
    return allocateHandle(.http2_cookie_box, context_id) orelse http_error_out_of_memory;
}

fn http2CookieFlush(id: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (isHandle(id, .http2_cookie_box)) errno.ok else http2_error_invalid_id;
}

fn http2SetCookieBox(id: i32, cookie_box: i32, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (!isHttp2OptionTarget(id) or !isHandle(cookie_box, .http2_cookie_box)) return http2_error_invalid_id;
    return errno.ok;
}

fn http2CreateRequestWithUrl(
    template_id: i32,
    method: ?[*:0]const u8,
    url: ?[*:0]const u8,
    _: u64,
) callconv(abi.guest) i32 {
    if (method == null or url == null) return http2_error_null_pointer;
    if (!isHandle(template_id, .http2_template)) return http2_error_invalid_id;
    return allocateHandle(.http2_request, template_id) orelse http_error_out_of_memory;
}

fn http2RequestOption(id: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (isHttp2OptionTarget(id)) errno.ok else http2_error_invalid_id;
}

fn http2RequestOnlyOption(id: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (isHandle(id, .http2_request)) errno.ok else http2_error_invalid_id;
}

fn http2AbortRequest(id: i32) callconv(abi.guest) i32 {
    if (!setRequestResult(id, http2_error_timeout)) return http2_error_invalid_id;
    return errno.ok;
}

fn http2SendRequest(id: i32, data: ?*const anyopaque, size: usize) callconv(abi.guest) i32 {
    if (data == null and size != 0) return http2_error_null_pointer;
    if (!setRequestResult(id, http2_error_timeout)) return http2_error_invalid_id;
    return http2_error_timeout;
}

fn http2GetStatusCode(id: i32, output: ?*i32) callconv(abi.guest) i32 {
    const status = output orelse return http2_error_null_pointer;
    status.* = 0;
    return requestResult(id) orelse http2_error_invalid_id;
}

fn http2GetContentLength(id: i32, result: ?*i32, length: ?*u64) callconv(abi.guest) i32 {
    const output_result = result orelse return http2_error_null_pointer;
    const output_length = length orelse return http2_error_null_pointer;
    output_result.* = -1;
    output_length.* = 0;
    return requestResult(id) orelse http2_error_invalid_id;
}

fn http2GetAllHeaders(id: i32, header: ?*?[*]u8, size: ?*usize) callconv(abi.guest) i32 {
    const output_header = header orelse return http2_error_null_pointer;
    const output_size = size orelse return http2_error_null_pointer;
    output_header.* = null;
    output_size.* = 0;
    return requestResult(id) orelse http2_error_invalid_id;
}

fn http2ReadData(id: i32, data: ?*anyopaque, size: usize) callconv(abi.guest) i32 {
    if (data == null and size != 0) return http2_error_null_pointer;
    return requestResult(id) orelse http2_error_invalid_id;
}

fn http2DeleteRequest(id: i32) callconv(abi.guest) i32 {
    return if (releaseHandle(id, .http2_request)) errno.ok else http2_error_invalid_id;
}

const http2_exports = [_]symbols.Export{
    .{ .name = "sceHttp2Init", .function = trace.wrap("sceHttp2Init", &http2Init), .expect_id = "3JCe3lCbQ8A" },
    .{ .name = "sceHttp2Term", .function = trace.wrap("sceHttp2Term", &http2Term), .expect_id = "YiBUtz-pGkc" },
    .{ .name = "sceHttp2CreateTemplate", .function = trace.wrap("sceHttp2CreateTemplate", &http2CreateTemplate), .expect_id = "+wCt7fCijgk" },
    .{ .name = "sceHttp2DeleteTemplate", .function = trace.wrap("sceHttp2DeleteTemplate", &http2DeleteTemplate), .expect_id = "pDom5-078DA" },
    .{ .name = "sceHttp2CreateCookieBox", .function = trace.wrap("sceHttp2CreateCookieBox", &http2CreateCookieBox), .expect_id = "N4UfjvWJsMw" },
    .{ .name = "sceHttp2SetCookieBox", .function = trace.wrap("sceHttp2SetCookieBox", &http2SetCookieBox), .expect_id = "jrVHsKCXA0g" },
    .{ .name = "sceHttp2CookieFlush", .function = trace.wrap("sceHttp2CookieFlush", &http2CookieFlush), .expect_id = "5VlQSzXW-SQ" },
    .{ .name = "sceHttp2CreateRequestWithURL", .function = trace.wrap("sceHttp2CreateRequestWithURL", &http2CreateRequestWithUrl), .expect_id = "mmyOCxQMVYQ" },
    .{ .name = "sceHttp2AbortRequest", .function = trace.wrap("sceHttp2AbortRequest", &http2AbortRequest), .expect_id = "IZ-qjhRqvjk" },
    .{ .name = "sceHttp2DeleteRequest", .function = trace.wrap("sceHttp2DeleteRequest", &http2DeleteRequest), .expect_id = "c8D9qIjo8EY" },
    .{ .name = "sceHttp2AddRequestHeader", .function = trace.wrap("sceHttp2AddRequestHeader", &http2RequestOnlyOption), .expect_id = "nrPfOE8TQu0" },
    .{ .name = "sceHttp2SetRequestContentLength", .function = trace.wrap("sceHttp2SetRequestContentLength", &http2RequestOnlyOption), .expect_id = "FSAFOzi0FpM" },
    .{ .name = "sceHttp2SetRequestNoContentLength", .function = trace.wrap("sceHttp2SetRequestNoContentLength", &http2RequestOnlyOption), .expect_id = "bEegosRhgM0" },
    .{ .name = "sceHttp2SetAuthEnabled", .function = trace.wrap("sceHttp2SetAuthEnabled", &http2RequestOption), .expect_id = "jjFahkBPCYs" },
    .{ .name = "sceHttp2SslDisableOption", .function = trace.wrap("sceHttp2SslDisableOption", &http2RequestOption), .expect_id = "B37SruheQ5Y" },
    .{ .name = "sceHttp2SslEnableOption", .function = trace.wrap("sceHttp2SslEnableOption", &http2RequestOption), .expect_id = "EWcwMpbr5F8" },
    .{ .name = "sceHttp2SetRedirectCallback", .function = trace.wrap("sceHttp2SetRedirectCallback", &http2RequestOption), .expect_id = "BJgi0CH7al4" },
    .{ .name = "sceHttp2SetRecvTimeOut", .function = trace.wrap("sceHttp2SetRecvTimeOut", &http2RequestOption), .expect_id = "izvHhqgDt44" },
    .{ .name = "sceHttp2SetSendTimeOut", .function = trace.wrap("sceHttp2SetSendTimeOut", &http2RequestOption), .expect_id = "XPtW45xiLHk" },
    .{ .name = "sceHttp2SetConnectTimeOut", .function = trace.wrap("sceHttp2SetConnectTimeOut", &http2RequestOption), .expect_id = "-HIO4VT87v8" },
    .{ .name = "sceHttp2SetSslCallback", .function = trace.wrap("sceHttp2SetSslCallback", &http2RequestOption), .expect_id = "YrWX+DhPHQY" },
    .{ .name = "sceHttp2SendRequest", .function = trace.wrap("sceHttp2SendRequest", &http2SendRequest), .expect_id = "rbqZig38AT8" },
    .{ .name = "sceHttp2GetResponseContentLength", .function = trace.wrap("sceHttp2GetResponseContentLength", &http2GetContentLength), .expect_id = "o0DBQpFE13o" },
    .{ .name = "sceHttp2GetStatusCode", .function = trace.wrap("sceHttp2GetStatusCode", &http2GetStatusCode), .expect_id = "9XYJwCf3lEA" },
    .{ .name = "sceHttp2GetAllResponseHeaders", .function = trace.wrap("sceHttp2GetAllResponseHeaders", &http2GetAllHeaders), .expect_id = "-rdXUi2XW90" },
    .{ .name = "sceHttp2ReadData", .function = trace.wrap("sceHttp2ReadData", &http2ReadData), .expect_id = "QygCNNmbGss" },
};

// libSceNpWebApi2 -----------------------------------------------------------

const WebApiResponseInfo = extern struct {
    http_status: i32 = 0,
    padding: u32 = 0,
    error_object: ?[*]u8 = null,
    error_object_size: usize = 0,
    response_data_size: usize = 0,
};

fn webApiInitialize(_: i32, pool_size: usize) callconv(abi.guest) i32 {
    if (pool_size == 0) return web_api_error_invalid_argument;
    return allocateHandle(.web_api_context, 0) orelse web_api_error_invalid_argument;
}

fn webApiTerminate(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .web_api_context)) errno.ok else web_api_error_invalid_argument;
}

fn webApiCreateUser(context_id: i32, _: i32) callconv(abi.guest) i32 {
    if (!isHandle(context_id, .web_api_context)) return web_api_error_invalid_argument;
    return allocateHandle(.web_api_user, context_id) orelse web_api_error_invalid_argument;
}

fn webApiDeleteUser(id: i32) callconv(abi.guest) i32 {
    return if (releaseTree(id, .web_api_user)) errno.ok else web_api_error_invalid_argument;
}

fn webApiCreateRequest(
    user_id: i32,
    api_group: ?[*:0]const u8,
    path: ?[*:0]const u8,
    method: ?[*:0]const u8,
    _: ?*const anyopaque,
    request_id: ?*i64,
) callconv(abi.guest) i32 {
    if (!isHandle(user_id, .web_api_user)) return web_api_error_invalid_argument;
    if (api_group == null or path == null or method == null or request_id == null) return web_api_error_invalid_argument;
    const id = allocateHandle(.web_api_request, user_id) orelse return web_api_error_invalid_argument;
    request_id.?.* = id;
    return errno.ok;
}

fn webApiRequestOption(id: i64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    const narrowed = std.math.cast(i32, id) orelse return web_api_error_request_not_found;
    return if (isHandle(narrowed, .web_api_request)) errno.ok else web_api_error_request_not_found;
}

fn webApiSendRequest(
    id: i64,
    _: ?*const anyopaque,
    _: usize,
    response: ?*WebApiResponseInfo,
) callconv(abi.guest) i32 {
    const narrowed = std.math.cast(i32, id) orelse return web_api_error_request_not_found;
    if (!isHandle(narrowed, .web_api_request)) return web_api_error_request_not_found;
    if (response) |info| {
        info.http_status = 0;
        info.response_data_size = 0;
        if (info.error_object) |buffer| if (info.error_object_size != 0) {
            buffer[0] = 0;
        };
    }
    return web_api_error_not_signed_in;
}

fn webApiReadData(id: i64, data: ?*anyopaque, size: usize) callconv(abi.guest) i32 {
    if (data == null or size == 0) return web_api_error_invalid_argument;
    const narrowed = std.math.cast(i32, id) orelse return web_api_error_request_not_found;
    return if (isHandle(narrowed, .web_api_request)) 0 else web_api_error_request_not_found;
}

fn webApiDeleteRequest(id: i64) callconv(abi.guest) i32 {
    const narrowed = std.math.cast(i32, id) orelse return web_api_error_request_not_found;
    return if (releaseHandle(narrowed, .web_api_request)) errno.ok else web_api_error_request_not_found;
}

fn webApiHeaderLength(id: i64, field: ?[*:0]const u8, length: ?*usize) callconv(abi.guest) i32 {
    if (field == null or length == null) return web_api_error_invalid_argument;
    const narrowed = std.math.cast(i32, id) orelse return web_api_error_request_not_found;
    if (!isHandle(narrowed, .web_api_request)) return web_api_error_request_not_found;
    length.?.* = 0;
    return errno.ok;
}

fn webApiHeaderValue(id: i64, field: ?[*:0]const u8, value: ?[*]u8, size: usize) callconv(abi.guest) i32 {
    if (field == null or value == null or size == 0) return web_api_error_invalid_argument;
    const narrowed = std.math.cast(i32, id) orelse return web_api_error_request_not_found;
    if (!isHandle(narrowed, .web_api_request)) return web_api_error_request_not_found;
    value.?[0] = 0;
    return errno.ok;
}

const web_api_exports = [_]symbols.Export{
    .{ .name = "sceNpWebApi2Initialize", .function = trace.wrap("sceNpWebApi2Initialize", &webApiInitialize), .expect_id = "+o9816YQhqQ" },
    .{ .name = "sceNpWebApi2Terminate", .function = trace.wrap("sceNpWebApi2Terminate", &webApiTerminate), .expect_id = "bEvXpcEk200" },
    .{ .name = "sceNpWebApi2CreateUserContext", .function = trace.wrap("sceNpWebApi2CreateUserContext", &webApiCreateUser), .expect_id = "sk54bi6FtYM" },
    .{ .name = "sceNpWebApi2DeleteUserContext", .function = trace.wrap("sceNpWebApi2DeleteUserContext", &webApiDeleteUser), .expect_id = "9X9+cneTGUU" },
    .{ .name = "sceNpWebApi2CreateRequest", .function = trace.wrap("sceNpWebApi2CreateRequest", &webApiCreateRequest), .expect_id = "3EI-OSJ65Xc" },
    .{ .name = "sceNpWebApi2AddHttpRequestHeader", .function = trace.wrap("sceNpWebApi2AddHttpRequestHeader", &webApiRequestOption), .expect_id = "egOOvrnF6mI" },
    .{ .name = "sceNpWebApi2SendRequest", .function = trace.wrap("sceNpWebApi2SendRequest", &webApiSendRequest), .expect_id = "lQOCF84lvzw" },
    .{ .name = "sceNpWebApi2ReadData", .function = trace.wrap("sceNpWebApi2ReadData", &webApiReadData), .expect_id = "OOY9+ObfKec" },
    .{ .name = "sceNpWebApi2DeleteRequest", .function = trace.wrap("sceNpWebApi2DeleteRequest", &webApiDeleteRequest), .expect_id = "vvzWO-DvG1s" },
    .{ .name = "sceNpWebApi2GetHttpResponseHeaderValueLength", .function = trace.wrap("sceNpWebApi2GetHttpResponseHeaderValueLength", &webApiHeaderLength), .expect_id = "HwP3aM+c85c" },
    .{ .name = "sceNpWebApi2GetHttpResponseHeaderValue", .function = trace.wrap("sceNpWebApi2GetHttpResponseHeaderValue", &webApiHeaderValue), .expect_id = "hksbskNToEA" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libSceNet", .version = 1 }, .{ .name = "libSceNet" }, &net_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSsl", .version = 1 }, .{ .name = "libSceSsl" }, &ssl_exports);
    try db.addLibrary(gpa, .{ .name = "libSceHttp", .version = 1 }, .{ .name = "libSceHttp" }, &http_exports);
    try db.addLibrary(gpa, .{ .name = "libSceHttp2", .version = 1 }, .{ .name = "libSceHttp2" }, &http2_exports);
    try db.addLibrary(gpa, .{ .name = "libSceNpWebApi2", .version = 1 }, .{ .name = "libSceNpWebApi2" }, &web_api_exports);
}

test "offline network keeps local handle lifecycle but rejects peer I/O" {
    reset();
    const pool = netPoolCreate("test", 4096, 0);
    try std.testing.expect(pool > 0);
    const resolver = netResolverCreate("dns", pool, 0);
    try std.testing.expect(resolver > 0);
    try std.testing.expectEqual(net_error_network_down, netResolverStartNtoa(resolver, "example.com", null, 0, 0, 0));

    const socket = netSocket("offline", 2, 1, 0);
    try std.testing.expect(socket > 0);
    try std.testing.expectEqual(errno.ok, netSocketAcceptsLocalState(socket, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(net_error_network_down, netSocketNeedsPeer(socket, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(net_error_network_down, netErrnoLoc().*);
    try std.testing.expectEqual(errno.ok, netSocketClose(socket));
}

test "HTTP URI parsing remains available while transport is offline" {
    var element = HttpUriElement{};
    var pool: [128]u8 = undefined;
    var required: usize = 0;
    try std.testing.expectEqual(errno.ok, httpUriParse(
        &element,
        "https://user:pass@example.com:8443/path?q=1#f",
        &pool,
        &required,
        pool.len,
    ));
    try std.testing.expectEqual(@as(u16, 8443), element.port);
    try std.testing.expectEqualStrings("https", std.mem.span(@as([*:0]u8, @ptrCast(element.scheme.?))));
    try std.testing.expectEqualStrings("example.com", std.mem.span(@as([*:0]u8, @ptrCast(element.hostname.?))));
    try std.testing.expect(required != 0);
}

test "HTTP2 send reports an offline timeout after successful setup" {
    reset();
    const context = http2Init(1, 1, 4096, 4);
    const template = http2CreateTemplate(context, "agent", 2, 0);
    const request = http2CreateRequestWithUrl(template, "GET", "https://example.com", 0);
    try std.testing.expect(context > 0 and template > 0 and request > 0);
    try std.testing.expectEqual(http2_error_timeout, http2SendRequest(request, null, 0));
    try std.testing.expectEqual(errno.ok, http2DeleteRequest(request));
    try std.testing.expectEqual(errno.ok, http2Term(context));
}

test "network families register the title import surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("OXXX4mUk3uk", .function) != null);
    try std.testing.expect(db.findById("IWalAn-guFs", .function) != null);
    try std.testing.expect(db.findById("IZ-qjhRqvjk", .function) != null);
    try std.testing.expect(db.findById("lQOCF84lvzw", .function) != null);
}
