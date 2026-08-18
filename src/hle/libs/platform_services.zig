// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bootstrap-level platform services imported by Unity support PRXs.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");
const kernel_memory = @import("kernel_memory.zig");

const rtc_unix_epoch_microseconds: i96 = 62_135_596_800 * std.time.us_per_s;
const rtc_error_invalid_pointer: i32 = @bitCast(@as(u32, 0x80b5_0002));
const rtc_error_invalid_value: i32 = @bitCast(@as(u32, 0x80b5_0004));
const rtc_error_invalid_year: i32 = @bitCast(@as(u32, 0x80b5_0008));
const gen2_error_memory_fault: i32 = @bitCast(@as(u32, 0x8002_0101));
const net_ctl_error_invalid_address: i32 = @bitCast(@as(u32, 0x8041_2107));
const net_ctl_error_not_connected: i32 = @bitCast(@as(u32, 0x8041_2108));

pub const RtcDateTime = extern struct {
    year: u16,
    month: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    microsecond: u32,
};

fn appContentInitialize(_: ?*const anyopaque, boot_param: ?*[40]u8) callconv(abi.guest) i32 {
    if (boot_param) |output| @memset(output, 0);
    return errno.ok;
}

/// Publishes the per-title scratch mount used by Unity's temporary-file layer.
///
/// `sceAppContentTemporaryDataMount2` takes a 32-bit option and a pointer to a
/// fixed 16-byte mount-point buffer.  Reporting success without filling that
/// buffer makes the caller construct paths from uninitialised data, which later
/// appears as an unrelated null dereference in the title.
fn temporaryDataMount2(_: u32, mount_point: ?*[16]u8) callconv(abi.guest) i32 {
    const output = mount_point orelse return errno.KernelError.einval.raw();
    @memset(output, 0);
    @memcpy(output[0.."/temp0".len], "/temp0");
    return errno.ok;
}

fn netCtlInit() callconv(abi.guest) i32 {
    return errno.ok;
}

fn netCtlTerm() callconv(abi.guest) void {}

fn netCtlGetNatInfo(output: ?*[16]u8) callconv(abi.guest) i32 {
    const info = output orelse return net_ctl_error_invalid_address;
    // Preserve the caller-supplied size field and report no mapped address.
    const size = info[0..4].*;
    @memset(info, 0);
    info[0..4].* = size;
    return errno.ok;
}

fn netCtlCheckCallback() callconv(abi.guest) i32 {
    // Guest callbacks are deliberately not invoked from an arbitrary HLE frame.
    // GetState/GetInfo expose the same disconnected state synchronously.
    return errno.ok;
}

fn netCtlGetState(output: ?*i32) callconv(abi.guest) i32 {
    const state = output orelse return net_ctl_error_invalid_address;
    state.* = 0; // SCE_NET_CTL_STATE_DISCONNECTED
    return errno.ok;
}

fn netCtlRegisterCallback(
    callback: ?*const anyopaque,
    _: ?*anyopaque,
    output: ?*i32,
) callconv(abi.guest) i32 {
    if (callback == null or output == null) return net_ctl_error_invalid_address;
    output.?.* = 0;
    return errno.ok;
}

fn netCtlUnregisterCallback(_: i32) callconv(abi.guest) i32 {
    return errno.ok;
}

fn netCtlGetResult(_: i32, output: ?*i32) callconv(abi.guest) i32 {
    const result = output orelse return net_ctl_error_invalid_address;
    result.* = errno.ok;
    return errno.ok;
}

fn netCtlGetInfo(_: i32, output: ?*[256]u8) callconv(abi.guest) i32 {
    const info = output orelse return net_ctl_error_invalid_address;
    @memset(info, 0);
    return net_ctl_error_not_connected;
}

fn rtcGetCurrentTick(output: ?*u64) callconv(abi.guest) i32 {
    const value = output orelse return errno.KernelError.einval.raw();
    const unix_microseconds = @divTrunc(
        kernel_runtime.realTimeNanoseconds(),
        std.time.ns_per_us,
    );
    value.* = @intCast(@max(@as(i96, 0), rtc_unix_epoch_microseconds + unix_microseconds));
    return errno.ok;
}

fn rtcGetCurrentNetworkTick(output: ?*u64) callconv(abi.guest) i32 {
    // There is no console network clock to query. The host real-time clock is
    // still expressed in the same RTC epoch and keeps offline titles moving.
    return rtcGetCurrentTick(output);
}

fn validRtcDateTime(value: RtcDateTime) bool {
    if (value.year < 1 or value.year > 9999 or value.month < 1 or value.month > 12) return false;
    if (value.hour > 23 or value.minute > 59 or value.second > 59 or value.microsecond >= std.time.us_per_s) return false;
    const month: std.time.epoch.Month = @enumFromInt(value.month);
    return value.day >= 1 and value.day <= std.time.epoch.getDaysInMonth(value.year, month);
}

/// Number of days since 1970-01-01. This is Howard Hinnant's civil-calendar
/// conversion, expressed with floor division so years before 1970 work too.
fn daysFromCivil(year_value: i64, month_value: i64, day_value: i64) i64 {
    var year = year_value;
    if (month_value <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month_value + (if (month_value > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day_value - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

fn civilFromDays(days_since_unix_epoch: i64) RtcDateTime {
    const adjusted = days_since_unix_epoch + 719_468;
    const era = @divFloor(adjusted, 146_097);
    const day_of_era = adjusted - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_piece = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_piece + 2, 5) + 1;
    const month = month_piece + (if (month_piece < 10) @as(i64, 3) else -9);
    if (month <= 2) year += 1;
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = 0,
        .minute = 0,
        .second = 0,
        .microsecond = 0,
    };
}

fn rtcDateTimeFromTick(tick: u64) ?RtcDateTime {
    const unix_microseconds: i128 = @as(i128, tick) - rtc_unix_epoch_microseconds;
    const microseconds_per_day: i128 = std.time.us_per_day;
    const days = @divFloor(unix_microseconds, microseconds_per_day);
    if (days < std.math.minInt(i64) or days > std.math.maxInt(i64)) return null;

    var result = civilFromDays(@intCast(days));
    if (result.year < 1 or result.year > 9999) return null;
    const into_day: u64 = @intCast(@mod(unix_microseconds, microseconds_per_day));
    result.hour = @intCast(into_day / std.time.us_per_hour);
    result.minute = @intCast((into_day % std.time.us_per_hour) / std.time.us_per_min);
    result.second = @intCast((into_day % std.time.us_per_min) / std.time.us_per_s);
    result.microsecond = @intCast(into_day % std.time.us_per_s);
    return result;
}

fn tickFromRtcDateTime(value: RtcDateTime) ?u64 {
    if (!validRtcDateTime(value)) return null;
    const days: i128 = daysFromCivil(value.year, value.month, value.day);
    const tick: i128 = rtc_unix_epoch_microseconds +
        days * std.time.us_per_day +
        @as(i128, value.hour) * std.time.us_per_hour +
        @as(i128, value.minute) * std.time.us_per_min +
        @as(i128, value.second) * std.time.us_per_s +
        value.microsecond;
    if (tick < 0 or tick > std.math.maxInt(u64)) return null;
    return @intCast(tick);
}

/// Longest string the RFC 3339 formatter can produce, including its
/// terminator: a full date and time with a numeric zone offset.
const rfc3339_maximum_length: usize = 26;

fn twoDigits(text: []const u8) ?u32 {
    if (text.len < 2) return null;
    if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1])) return null;
    return (@as(u32, text[0] - '0') * 10) + (text[1] - '0');
}

fn fourDigits(text: []const u8) ?u32 {
    if (text.len < 4) return null;
    var value: u32 = 0;
    for (text[0..4]) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        value = value * 10 + (digit - '0');
    }
    return value;
}

const ParsedRfc3339 = struct {
    date_time: RtcDateTime,
    offset_minutes: i32,
};

/// Reads one RFC 3339 date and time, with the zone it was written in.
///
/// The grammar is fixed by the standard, so this accepts exactly what the
/// standard allows and nothing more: a full date, a `T` or `t` separator, a
/// time, an optional fractional second of any length, and either `Z` for UTC
/// or a signed hour-and-minute offset. Anything else is a malformed value
/// rather than something to guess at.
fn parseRfc3339(text: []const u8) ?ParsedRfc3339 {
    if (text.len < 20) return null;
    const year = fourDigits(text[0..]) orelse return null;
    if (text[4] != '-') return null;
    const month = twoDigits(text[5..]) orelse return null;
    if (text[7] != '-') return null;
    const day = twoDigits(text[8..]) orelse return null;
    if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return null;
    const hour = twoDigits(text[11..]) orelse return null;
    if (text[13] != ':') return null;
    const minute = twoDigits(text[14..]) orelse return null;
    if (text[16] != ':') return null;
    const second = twoDigits(text[17..]) orelse return null;

    var index: usize = 19;
    var microsecond: u32 = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        var scale: u32 = 100_000;
        var digits: usize = 0;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            // Beyond microsecond resolution the remaining digits are read and
            // discarded: they are well formed, they simply cannot be kept.
            if (scale != 0) {
                microsecond += @as(u32, text[index] - '0') * scale;
                scale /= 10;
            }
            digits += 1;
        }
        if (digits == 0) return null;
    }

    if (index >= text.len) return null;
    var offset_minutes: i32 = 0;
    switch (text[index]) {
        'Z', 'z' => index += 1,
        '+', '-' => {
            const negative = text[index] == '-';
            index += 1;
            const offset_hour = twoDigits(text[index..]) orelse return null;
            index += 2;
            if (index >= text.len or text[index] != ':') return null;
            index += 1;
            const offset_minute = twoDigits(text[index..]) orelse return null;
            index += 2;
            if (offset_hour > 23 or offset_minute > 59) return null;
            const magnitude: i32 = @intCast(offset_hour * 60 + offset_minute);
            offset_minutes = if (negative) -magnitude else magnitude;
        },
        else => return null,
    }
    if (index != text.len) return null;

    const value = RtcDateTime{
        .year = std.math.cast(u16, year) orelse return null,
        .month = std.math.cast(u16, month) orelse return null,
        .day = std.math.cast(u16, day) orelse return null,
        .hour = std.math.cast(u16, hour) orelse return null,
        .minute = std.math.cast(u16, minute) orelse return null,
        .second = std.math.cast(u16, second) orelse return null,
        .microsecond = microsecond,
    };
    if (!validRtcDateTime(value)) return null;
    return .{ .date_time = value, .offset_minutes = offset_minutes };
}

/// Converts a tick to the calendar reading seen at a given zone offset.
fn shiftedDateTime(tick: u64, offset_minutes: i32) ?RtcDateTime {
    const shifted: i128 = @as(i128, tick) +
        @as(i128, offset_minutes) * @as(i128, std.time.us_per_min);
    if (shifted < 0 or shifted > std.math.maxInt(u64)) return null;
    return rtcDateTimeFromTick(@intCast(shifted));
}

pub fn rtcFormatRFC3339(
    output: ?[*]u8,
    tick_pointer: ?*const u64,
    time_zone_minutes: i32,
) callconv(abi.guest) i32 {
    const destination = output orelse return rtc_error_invalid_pointer;
    const source = tick_pointer orelse return rtc_error_invalid_pointer;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), rfc3339_maximum_length) or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(source), @sizeOf(u64)))
    {
        return gen2_error_memory_fault;
    }
    if (time_zone_minutes < -23 * 60 or time_zone_minutes > 23 * 60) return rtc_error_invalid_value;
    const local = shiftedDateTime(source.*, time_zone_minutes) orelse return rtc_error_invalid_value;

    var buffer: [rfc3339_maximum_length]u8 = @splat(0);
    const text = if (time_zone_minutes == 0)
        std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            local.year, local.month, local.day, local.hour, local.minute, local.second,
        }) catch return rtc_error_invalid_value
    else text: {
        const negative = time_zone_minutes < 0;
        const magnitude: u32 = @intCast(if (negative) -time_zone_minutes else time_zone_minutes);
        break :text std.fmt.bufPrint(
            &buffer,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}",
            .{
                local.year,       local.month, local.day,
                local.hour,       local.minute, local.second,
                @as(u8, if (negative) '-' else '+'),
                magnitude / 60,   magnitude % 60,
            },
        ) catch return rtc_error_invalid_value;
    };
    @memcpy(destination[0..text.len], text);
    destination[text.len] = 0;
    return errno.ok;
}

pub fn rtcParseRFC3339(tick_pointer: ?*u64, text_pointer: ?[*:0]const u8) callconv(abi.guest) i32 {
    const destination = tick_pointer orelse return rtc_error_invalid_pointer;
    const source = text_pointer orelse return rtc_error_invalid_pointer;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u64))) {
        return gen2_error_memory_fault;
    }
    const text = std.mem.sliceTo(source, 0);
    const parsed = parseRfc3339(text) orelse return rtc_error_invalid_value;
    const local_tick = tickFromRtcDateTime(parsed.date_time) orelse return rtc_error_invalid_value;
    // The string carries the zone it was written in; the tick is always UTC.
    const utc: i128 = @as(i128, local_tick) -
        @as(i128, parsed.offset_minutes) * @as(i128, std.time.us_per_min);
    if (utc < 0 or utc > std.math.maxInt(u64)) return rtc_error_invalid_value;
    destination.* = @intCast(utc);
    return errno.ok;
}

fn checkedRtcOutput(output: ?*RtcDateTime) ?*RtcDateTime {
    const destination = output orelse return null;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(RtcDateTime))) return null;
    return destination;
}

pub fn rtcGetCurrentClockLocalTime(output: ?*RtcDateTime) callconv(abi.guest) i32 {
    const destination = output orelse return rtc_error_invalid_pointer;
    if (checkedRtcOutput(destination) == null) return gen2_error_memory_fault;
    const unix_nanoseconds = @max(@as(i96, 0), kernel_runtime.realTimeNanoseconds());
    const unix_microseconds: u64 = @intCast(@divTrunc(unix_nanoseconds, std.time.ns_per_us));
    destination.* = rtcDateTimeFromTick(@intCast(rtc_unix_epoch_microseconds + unix_microseconds)) orelse
        return rtc_error_invalid_value;
    return errno.ok;
}

pub fn rtcSetTick(output: ?*RtcDateTime, tick_pointer: ?*const u64) callconv(abi.guest) i32 {
    const destination = output orelse return rtc_error_invalid_pointer;
    const source = tick_pointer orelse return rtc_error_invalid_pointer;
    if (checkedRtcOutput(destination) == null or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(source), @sizeOf(u64)))
    {
        return gen2_error_memory_fault;
    }
    destination.* = rtcDateTimeFromTick(source.*) orelse return rtc_error_invalid_value;
    return errno.ok;
}

pub fn rtcGetTickResolution() callconv(abi.guest) u64 {
    return std.time.us_per_s;
}

pub fn rtcIsLeapYear(year: i32) callconv(abi.guest) i32 {
    if (year < 1 or year > 9999) return rtc_error_invalid_year;
    return @intFromBool(std.time.epoch.isLeapYear(@intCast(year)));
}

pub fn rtcGetDayOfWeek(year: i32, month: i32, day: i32) callconv(abi.guest) i32 {
    if (year < 1 or year > 9999 or month < 1 or month > 12 or day < 1) return rtc_error_invalid_value;
    const month_enum: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(month)));
    if (day > std.time.epoch.getDaysInMonth(@intCast(year), month_enum)) return rtc_error_invalid_value;
    // The firmware uses Sunday=0; 1970-01-01 was Thursday=4.
    return @intCast(@mod(daysFromCivil(year, month, day) + 4, 7));
}

pub fn rtcGetTick(time_pointer: ?*const RtcDateTime, output: ?*u64) callconv(abi.guest) i32 {
    const source = time_pointer orelse return rtc_error_invalid_pointer;
    const destination = output orelse return rtc_error_invalid_pointer;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(source), @sizeOf(RtcDateTime)) or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u64)))
    {
        return gen2_error_memory_fault;
    }
    destination.* = tickFromRtcDateTime(source.*) orelse return rtc_error_invalid_value;
    return errno.ok;
}

pub fn rtcGetTimeT(time_pointer: ?*const RtcDateTime, output: ?*i64) callconv(abi.guest) i32 {
    const source = time_pointer orelse return rtc_error_invalid_pointer;
    const destination = output orelse return rtc_error_invalid_pointer;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(source), @sizeOf(RtcDateTime)) or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(i64)))
    {
        return gen2_error_memory_fault;
    }
    const tick = tickFromRtcDateTime(source.*) orelse return rtc_error_invalid_value;
    destination.* = if (tick < rtc_unix_epoch_microseconds)
        0
    else
        @intCast(@divTrunc(tick - rtc_unix_epoch_microseconds, std.time.us_per_s));
    return errno.ok;
}

const app_content_exports = [_]symbols.Export{
    .{ .name = "sceAppContentInitialize", .function = trace.wrap("sceAppContentInitialize", &appContentInitialize), .expect_id = "R9lA82OraNs" },
    .{ .name = "sceAppContentTemporaryDataMount2", .function = trace.wrap("sceAppContentTemporaryDataMount2", &temporaryDataMount2), .expect_id = "buYbeLOGWmA" },
};

const net_ctl_exports = [_]symbols.Export{
    .{ .name = "sceNetCtlInit", .function = trace.wrap("sceNetCtlInit", &netCtlInit), .expect_id = "gky0+oaNM4k" },
    .{ .name = "sceNetCtlTerm", .function = trace.wrap("sceNetCtlTerm", &netCtlTerm), .expect_id = "Z4wwCFiBELQ" },
    .{ .name = "sceNetCtlGetNatInfo", .function = trace.wrap("sceNetCtlGetNatInfo", &netCtlGetNatInfo), .expect_id = "JO4yuTuMoKI" },
    .{ .name = "sceNetCtlCheckCallback", .function = trace.wrap("sceNetCtlCheckCallback", &netCtlCheckCallback), .expect_id = "iQw3iQPhvUQ" },
    .{ .name = "sceNetCtlGetState", .function = trace.wrap("sceNetCtlGetState", &netCtlGetState), .expect_id = "uBPlr0lbuiI" },
    .{ .name = "sceNetCtlGetStateV6", .function = trace.wrap("sceNetCtlGetStateV6", &netCtlGetState), .expect_id = "+lxqIKeU9UY" },
    .{ .name = "sceNetCtlRegisterCallback", .function = trace.wrap("sceNetCtlRegisterCallback", &netCtlRegisterCallback), .expect_id = "UJ+Z7Q+4ck0" },
    .{ .name = "sceNetCtlUnregisterCallback", .function = trace.wrap("sceNetCtlUnregisterCallback", &netCtlUnregisterCallback), .expect_id = "Rqm2OnZMCz0" },
    .{ .name = "sceNetCtlGetResult", .function = trace.wrap("sceNetCtlGetResult", &netCtlGetResult), .expect_id = "0cBgduPRR+M" },
    .{ .name = "sceNetCtlGetInfo", .function = trace.wrap("sceNetCtlGetInfo", &netCtlGetInfo), .expect_id = "obuxdTiwkF8" },
};

const rtc_exports = [_]symbols.Export{
    .{
        .name = "sceRtcGetCurrentTick",
        .function = trace.wrap("sceRtcGetCurrentTick", &rtcGetCurrentTick),
        .expect_id = "18B2NS1y9UU",
    },
    .{
        .name = "sceRtcGetCurrentNetworkTick",
        .function = trace.wrap("sceRtcGetCurrentNetworkTick", &rtcGetCurrentNetworkTick),
        .expect_id = "zO9UL3qIINQ",
    },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(
        gpa,
        .{ .name = "libSceAppContent", .version = 1 },
        .{ .name = "libSceAppContentUtil", .version_major = 1, .version_minor = 1 },
        &app_content_exports,
    );
    try db.addLibrary(
        gpa,
        .{ .name = "libSceNetCtl", .version = 1 },
        .{ .name = "libSceNetCtl", .version_major = 1, .version_minor = 1 },
        &net_ctl_exports,
    );
    try db.addLibrary(
        gpa,
        .{ .name = "libSceRtc", .version = 1 },
        .{ .name = "libSceRtc", .version_major = 1, .version_minor = 1 },
        &rtc_exports,
    );
}

test "Unity bootstrap platform services register" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findByName("sceAppContentInitialize", .function) != null);
    try std.testing.expect(db.findByName("sceRtcGetCurrentTick", .function) != null);
}

test "RTC calendar and tick conversions preserve subsecond time" {
    const date = RtcDateTime{
        .year = 2024,
        .month = 2,
        .day = 29,
        .hour = 23,
        .minute = 58,
        .second = 57,
        .microsecond = 654_321,
    };
    const tick = tickFromRtcDateTime(date) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualDeep(date, rtcDateTimeFromTick(tick).?);
    try std.testing.expectEqual(@as(i32, 4), rtcGetDayOfWeek(1970, 1, 1));
    try std.testing.expectEqual(@as(i32, 1), rtcIsLeapYear(2024));
    try std.testing.expectEqual(@as(i32, 0), rtcIsLeapYear(2023));
}

test "network control reports a coherent disconnected console" {
    var state: i32 = -1;
    try std.testing.expectEqual(errno.ok, netCtlGetState(&state));
    try std.testing.expectEqual(@as(i32, 0), state);
    var info: [256]u8 = [_]u8{0xff} ** 256;
    try std.testing.expectEqual(net_ctl_error_not_connected, netCtlGetInfo(14, &info));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 256), &info);
}

test "temporary data mount returns a zero-terminated mount point" {
    var mount_point: [16]u8 = [_]u8{0xff} ** 16;
    try std.testing.expectEqual(errno.ok, temporaryDataMount2(1, &mount_point));
    try std.testing.expectEqualStrings("/temp0", std.mem.sliceTo(&mount_point, 0));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9), mount_point[7..]);
    try std.testing.expectEqual(errno.KernelError.einval.raw(), temporaryDataMount2(0, null));
}

test "RFC 3339 text and RTC ticks convert in both directions" {
    // 2024-02-29T12:34:56.789012Z — a leap day, so the calendar arithmetic is
    // exercised rather than assumed.
    const parsed = parseRfc3339("2024-02-29T12:34:56.789012Z") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 2024), parsed.date_time.year);
    try std.testing.expectEqual(@as(u16, 2), parsed.date_time.month);
    try std.testing.expectEqual(@as(u16, 29), parsed.date_time.day);
    try std.testing.expectEqual(@as(u16, 12), parsed.date_time.hour);
    try std.testing.expectEqual(@as(u32, 789_012), parsed.date_time.microsecond);
    try std.testing.expectEqual(@as(i32, 0), parsed.offset_minutes);

    // A zone offset moves the instant, not the reading: both spellings below
    // name the same moment.
    const utc = parseRfc3339("2024-02-29T12:00:00Z") orelse return error.TestUnexpectedResult;
    const shifted = parseRfc3339("2024-02-29T14:30:00+02:30") orelse return error.TestUnexpectedResult;
    const utc_tick = tickFromRtcDateTime(utc.date_time) orelse return error.TestUnexpectedResult;
    const shifted_tick = tickFromRtcDateTime(shifted.date_time) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(i128, utc_tick),
        @as(i128, shifted_tick) - @as(i128, shifted.offset_minutes) * std.time.us_per_min,
    );

    // Round trip through the formatter, which writes UTC as `Z`.
    var tick: u64 = utc_tick;
    var text: [rfc3339_maximum_length]u8 = @splat(0xaa);
    try std.testing.expectEqual(errno.ok, rtcFormatRFC3339(&text, &tick, 0));
    try std.testing.expectEqualStrings("2024-02-29T12:00:00Z", std.mem.sliceTo(&text, 0));

    // And with an offset, which shifts the printed reading and names itself.
    try std.testing.expectEqual(errno.ok, rtcFormatRFC3339(&text, &tick, -90));
    try std.testing.expectEqualStrings("2024-02-29T10:30:00-01:30", std.mem.sliceTo(&text, 0));
}

test "malformed RFC 3339 text is refused rather than guessed at" {
    try std.testing.expect(parseRfc3339("2024-02-30T00:00:00Z") == null); // no such day
    try std.testing.expect(parseRfc3339("2024-02-29T12:00:00") == null); // no zone
    try std.testing.expect(parseRfc3339("2024-02-29 12:00:00Z extra") == null); // trailing text
    try std.testing.expect(parseRfc3339("2024-02-29T12:00:00.Z") == null); // empty fraction
    try std.testing.expect(parseRfc3339("2024-02-29T12:00:00+2:00") == null); // short offset
    try std.testing.expect(parseRfc3339("") == null);
}
