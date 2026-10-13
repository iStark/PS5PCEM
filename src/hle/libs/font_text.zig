// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Font strings and horizontal writing runs. Parser callbacks execute through
//! the guest dispatcher; glyph metrics come from the existing FreeType faces.
//! ABI shapes were cross-checked with KytyPS5 and AnyPS5's Font interfaces.
const std = @import("std");
const memory = @import("memory");
const font = @import("font.zig");
const abi = @import("../abi.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");
const threading = @import("kernel_threading.zig");
const GlyphMetrics = @import("../font_rasterizer.zig").Metrics;
const allocator = std.heap.page_allocator;
const invalid: i32 = @bitCast(@as(u32, 0x80460002));
const unsupported: i32 = @bitCast(@as(u32, 0x80460020));
const no_memory: i32 = @bitCast(@as(u32, 0x80460010));

const Source = extern struct {
    magic: u64 = (@as(u64, 0x10) << 32) | 0x0f04,
    start: usize = 0,
    end: usize = 0,
    current: usize = 0,
    parser: usize = 0,
    object: usize = 0,
    default_font: usize = 0,
    reserved: [5]usize = @splat(0),
};
const Detail = extern struct { id: u16, kind: u8, detections: u8, options: u32, default_font: usize, callback: usize, object: usize };
const ParseResult = extern struct { font: usize = 0, code: u32 = 0, padding: u32 = 0, reserved: [2]usize = @splat(0) };
const Character = struct { owner: *String, index: usize, font: usize, code: u32, order: usize };
const String = struct { chars: std.ArrayList(Character) = .empty, form: i32 = 0x12, terminate: u32 = 0, end_order: usize = 0 };
const Metrics = extern struct { advance_x: f32 = 0, advance_y: f32 = 0, top: f32 = 0, bottom: f32 = 0, left: f32 = 0, right: f32 = 0 };
const Step = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    advance_x: f32 = 0,
    advance_y: f32 = 0,
    font: usize = 0,
    profile: u32 = 0,
    code: u32 = 0,
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    glyph: GlyphMetrics = .{},
};
const Letter = extern struct { x: f32 = 0, y: f32 = 0, advance_x: f32 = 0, advance_y: f32 = 0, fields: [12]u32 = @splat(0) };
const Writing = extern struct {
    magic: u64 = 0,
    string: usize = 0,
    next_index: usize = 0,
    character: usize = 0,
    step: Step = .{},
    metrics: Metrics = .{},
    letter: Letter = .{},
    reserved: [8]usize = @splat(0),
};
const LineStep = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    advance_x: f32 = 0,
    advance_y: f32 = 0,
    spacing: f32 = 0,
    orderer: usize = 0,
    adjust_x: f32 = 0,
    adjust_y: f32 = 0,
    metrics: Metrics = .{},
};
const Line = struct {
    steps: std.ArrayList(LineStep) = .empty,
    cursor: usize = 0,
    metrics: Metrics = .{},
    render_metrics: Metrics = .{},
    step: LineStep = .{},
    ordering_space: f32 = 0,
    last_attribute: u64 = 0,
};
var mutex: memory.HostMutex = .{};
var strings: std.ArrayList(*String) = .empty;
var lines: std.ArrayList(*Line) = .empty;

comptime {
    if (@sizeOf(Source) != 96 or @sizeOf(Writing) != 256 or @sizeOf(Step) != 72 or @sizeOf(Letter) != 64 or @sizeOf(LineStep) != 64) @compileError("font text ABI");
}
pub fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (strings.items) |s| {
        s.chars.deinit(allocator);
        allocator.destroy(s);
    }
    strings.deinit(allocator);
    strings = .empty;
    for (lines.items) |l| {
        l.steps.deinit(allocator);
        allocator.destroy(l);
    }
    lines.deinit(allocator);
    lines = .empty;
}
fn out(comptime T: type, pointer: ?*T) bool {
    if (pointer) |p| {
        if (!font.writable(@intFromPtr(p), @sizeOf(T))) return false;
        font.notifyWrite(@intFromPtr(p), @sizeOf(T));
        return true;
    }
    return false;
}
fn input(comptime T: type, pointer: ?*const T) bool {
    return if (pointer) |p| font.readable(@intFromPtr(p), @sizeOf(T)) else false;
}
fn findString(handle: usize) ?*String {
    for (strings.items) |s| {
        if (@intFromPtr(s) == handle) return s;
    }
    return null;
}
fn findLine(handle: usize) ?*Line {
    for (lines.items) |l| {
        if (@intFromPtr(l) == handle) return l;
    }
    return null;
}
fn findChar(handle: usize) ?*Character {
    if (handle == 0) return null;
    for (strings.items) |s| {
        const base = @intFromPtr(s.chars.items.ptr);
        if (handle >= base and handle - base < s.chars.items.len * @sizeOf(Character) and (handle - base) % @sizeOf(Character) == 0)
            return &s.chars.items[(handle - base) / @sizeOf(Character)];
    }
    return null;
}
fn sourceInit(p: ?*Source, address: usize, size: u32, parser: usize, object: usize) callconv(abi.guest) i32 {
    if (!out(Source, p)) return invalid;
    const end = if (size != 0) std.math.add(usize, address, size) catch return invalid else 0;
    if (size != 0 and !font.readable(address, size)) return invalid;
    p.?.* = .{ .start = address, .current = address, .end = end, .parser = parser, .object = object, .reserved = .{ address, end, parser, object, 0 } };
    return 0;
}
fn sourceForm(p: ?*Source, form: i32) callconv(abi.guest) i32 {
    if (!out(Source, p)) return invalid;
    if (form != 0x10 and form != 0x12) return unsupported;
    p.?.magic = (@as(u64, @intCast(form)) << 32) | 0x0f04;
    return 0;
}
fn sourceFont(p: ?*Source, handle: usize) callconv(abi.guest) i32 {
    if (!out(Source, p)) return invalid;
    p.?.default_font = handle;
    p.?.reserved[4] = handle;
    return 0;
}
fn createString(_: usize, p: ?*Source, detail: ?*const Detail, output: ?*usize) callconv(abi.guest) i32 {
    if (!out(Source, p) or !out(usize, output)) return invalid;
    if (detail != null and !input(Detail, detail)) return invalid;
    const source = p.?;
    output.?.* = 0;
    const default_font = if (source.default_font != 0) source.default_font else if (detail) |d| d.default_font else 0;
    if (detail) |d| if (d.callback != 0 or d.options != 0) return unsupported;
    const s = allocator.create(String) catch return no_memory;
    s.* = .{ .form = @intCast(source.magic >> 32) };
    var published = false;
    defer if (!published) {
        s.chars.deinit(allocator);
        allocator.destroy(s);
    };
    for (0..65536) |_| {
        var result = ParseResult{ .font = default_font };
        var order = source.current;
        var status: i32 = 0;
        if (source.parser != 0) {
            const raw = threading.callGuestCurrent(source.parser, &.{ @intFromPtr(source), @intFromPtr(&order), @intFromPtr(&result) }) catch return invalid;
            status = @bitCast(@as(u32, @truncate(raw)));
        } else {
            if (source.current >= source.end) break;
            if (!font.readable(source.current, source.end - source.current)) return invalid;
            const bytes: [*]const u8 = @ptrFromInt(source.current);
            if (bytes[0] == 0) break;
            const count = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return invalid;
            if (count > source.end - source.current) return invalid;
            result.code = std.unicode.utf8Decode(bytes[0..count]) catch return invalid;
            source.current += count;
            status = 1;
        }
        if (status == 0) {
            s.terminate = result.code;
            s.end_order = order;
            break;
        }
        if (status != 1) return if (@as(i32, @bitCast(result.code)) < 0) @bitCast(result.code) else invalid;
        s.chars.append(allocator, .{ .owner = s, .index = s.chars.items.len, .font = if (result.font != 0) result.font else default_font, .code = result.code, .order = order }) catch return no_memory;
    } else return invalid;
    mutex.lock();
    defer mutex.unlock();
    strings.append(allocator, s) catch return no_memory;
    output.?.* = @intFromPtr(s);
    published = true;
    return 0;
}
fn destroyString(output: ?*usize) callconv(abi.guest) i32 {
    if (!out(usize, output)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    for (strings.items, 0..) |s, i| if (@intFromPtr(s) == output.?.*) {
        s.chars.deinit(allocator);
        allocator.destroy(s);
        _ = strings.swapRemove(i);
        output.?.* = 0;
        return 0;
    };
    return invalid;
}
fn stringForm(handle: usize) callconv(abi.guest) i32 {
    mutex.lock();
    defer mutex.unlock();
    return (findString(handle) orelse return invalid).form;
}
fn terminateCode(handle: usize) callconv(abi.guest) u32 {
    mutex.lock();
    defer mutex.unlock();
    return (findString(handle) orelse return 0).terminate;
}
fn textChars(handle: usize, count: ?*u32) callconv(abi.guest) usize {
    if (!out(u32, count)) return 0;
    mutex.lock();
    defer mutex.unlock();
    const s = findString(handle) orelse {
        count.?.* = 0;
        return 0;
    };
    count.?.* = @intCast(s.chars.items.len);
    return if (s.chars.items.len == 0) 0 else @intFromPtr(s.chars.items.ptr);
}
fn renderChars(handle: usize, first: usize, last: usize, count: ?*u32) callconv(abi.guest) usize {
    if (!out(u32, count)) return 0;
    count.?.* = 0;
    mutex.lock();
    defer mutex.unlock();
    const s = findString(handle) orelse return 0;
    if (s.chars.items.len == 0) return 0;
    const c = if (first == 0) &s.chars.items[0] else findChar(first) orelse return 0;
    if (c.owner != s) return 0;
    const end = if (last == 0) s.chars.items.len else blk: {
        const l = findChar(last) orelse return 0;
        if (l.owner != s) return 0;
        break :blk l.index + 1;
    };
    if (end <= c.index) return 0;
    count.?.* = @intCast(end - c.index);
    return @intFromPtr(c);
}
fn nextChar(handle: usize) callconv(abi.guest) usize {
    mutex.lock();
    defer mutex.unlock();
    const c = findChar(handle) orelse return 0;
    return if (c.index + 1 < c.owner.chars.items.len) @intFromPtr(&c.owner.chars.items[c.index + 1]) else 0;
}
fn charCode(handle: usize, f: ?*usize, code: ?*u32) callconv(abi.guest) i32 {
    if (!out(usize, f) or !out(u32, code)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    const c = findChar(handle) orelse return invalid;
    f.?.* = c.font;
    code.?.* = c.code;
    return 0;
}
fn charOrder(handle: usize, order: ?*usize) callconv(abi.guest) i32 {
    if (!out(usize, order)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    order.?.* = (findChar(handle) orelse return invalid).order;
    return 0;
}
fn bidiLevel(handle: usize, level: ?*i32) callconv(abi.guest) i32 {
    if (!out(i32, level)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    const c = findChar(handle) orelse return invalid;
    if (c.code >= 0x590 and c.code <= 0x8ff) return unsupported;
    level.?.* = 0;
    return 0;
}
fn whitespace(code: u32) bool {
    return switch (code) {
        9...13, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
fn charWhitespace(handle: usize) callconv(abi.guest) u32 {
    mutex.lock();
    defer mutex.unlock();
    const code = (findChar(handle) orelse return 0).code;
    return if (whitespace(code)) code else 0;
}
fn writingInit(p: ?*Writing, handle: usize, character: usize) callconv(abi.guest) i32 {
    if (!out(Writing, p)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    const s = findString(handle) orelse return invalid;
    const index = if (character == 0) 0 else blk: {
        const c = findChar(character) orelse return invalid;
        if (c.owner != s) return invalid;
        break :blk c.index;
    };
    p.?.* = .{ .magic = 0x0f06, .string = handle, .next_index = index };
    return 0;
}
fn appendMetrics(total: *Metrics, m: Metrics, first: bool) void {
    const left = total.advance_x + m.left;
    const right = total.advance_x + m.right;
    const top = total.advance_y + m.top;
    const bottom = total.advance_y + m.bottom;
    total.left = if (first) left else @min(total.left, left);
    total.right = if (first) right else @max(total.right, right);
    total.top = if (first) top else @min(total.top, top);
    total.bottom = if (first) bottom else @max(total.bottom, bottom);
    total.advance_x += m.advance_x;
    total.advance_y += m.advance_y;
}
fn writingStep(p: ?*Writing) callconv(abi.guest) ?*const Step {
    if (!out(Writing, p) or p.?.magic != 0x0f06) return null;
    mutex.lock();
    defer mutex.unlock();
    const w = p.?;
    const s = findString(w.string) orelse return null;
    if (w.next_index >= s.chars.items.len) {
        w.character = 0;
        return null;
    }
    const c = &s.chars.items[w.next_index];
    var gm: GlyphMetrics = .{};
    if (font.metricsImpl(c.font, c.code, &gm, true) != 0) return null;
    const m = Metrics{ .advance_x = gm.horizontal_advance, .top = -gm.horizontal_bearing_y, .bottom = gm.height - gm.horizontal_bearing_y, .left = gm.horizontal_bearing_x, .right = gm.horizontal_bearing_x + gm.width };
    w.step = .{ .x = w.metrics.advance_x, .y = w.metrics.advance_y, .advance_x = m.advance_x, .font = c.font, .profile = 1 | (@as(u32, @intFromBool(gm.width == 0 or gm.height == 0)) << 8), .code = c.code, .glyph = gm };
    w.letter = .{ .x = w.step.x, .y = w.step.y, .advance_x = w.step.advance_x };
    w.letter.fields[0] = 1;
    w.letter.fields[1] = @intCast(c.index);
    w.letter.fields[2] = 1;
    w.letter.fields[3] = @intCast(c.index);
    w.letter.fields[5] = 0x00000100;
    appendMetrics(&w.metrics, m, w.character == 0);
    w.character = @intFromPtr(c);
    w.next_index += 1;
    return &w.step;
}
fn writingChar(p: ?*Writing, letter: ?*usize) callconv(abi.guest) usize {
    if (!input(Writing, p) or p.?.magic != 0x0f06) return 0;
    if (letter != null) {
        if (!out(usize, letter)) return 0;
        letter.?.* = @intFromPtr(&p.?.letter);
    }
    return p.?.character;
}
fn writingMetrics(p: ?*Writing, output: ?*Metrics) callconv(abi.guest) i32 {
    if (!input(Writing, p) or p.?.magic != 0x0f06 or !out(Metrics, output)) return invalid;
    output.?.* = p.?.metrics;
    return 0;
}
fn createLine(_: usize, form: i32, detail: usize, output: ?*usize) callconv(abi.guest) i32 {
    if (!out(usize, output)) return invalid;
    if ((form != 0x10 and form != 0x12) or detail != 0) return unsupported;
    mutex.lock();
    defer mutex.unlock();
    const l = allocator.create(Line) catch return no_memory;
    l.* = .{};
    lines.append(allocator, l) catch {
        allocator.destroy(l);
        return no_memory;
    };
    output.?.* = @intFromPtr(l);
    return 0;
}
fn destroyLine(output: ?*usize) callconv(abi.guest) i32 {
    if (!out(usize, output)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    for (lines.items, 0..) |l, i| if (@intFromPtr(l) == output.?.*) {
        l.steps.deinit(allocator);
        allocator.destroy(l);
        _ = lines.swapRemove(i);
        output.?.* = 0;
        return 0;
    };
    return invalid;
}
fn clearLine(handle: usize) callconv(abi.guest) i32 {
    mutex.lock();
    defer mutex.unlock();
    const l = findLine(handle) orelse return invalid;
    l.steps.clearRetainingCapacity();
    l.cursor = 0;
    l.metrics = .{};
    l.render_metrics = .{};
    l.step = .{};
    l.ordering_space = 0;
    l.last_attribute = 0;
    return 0;
}
fn lineOrder(handle: usize, attr: u64, metrics: ?*const Metrics, orderer: usize) callconv(abi.guest) i32 {
    if (metrics != null and !input(Metrics, metrics)) return invalid;
    // Horizontal level-zero runs only; bidirectional reordering is explicit debt.
    if (attr != 0 and (attr & 0xffff != 0xfa or attr >> 32 != 0)) return unsupported;
    mutex.lock();
    defer mutex.unlock();
    const l = findLine(handle) orelse return invalid;
    const m = if (metrics) |p| p.* else Metrics{};
    var space = l.ordering_space;
    if (l.steps.items.len != 0 and ((l.last_attribute & (@as(u64, 1) << 31) != 0) or (attr & (@as(u64, 1) << 30) != 0))) {
        const previous = l.steps.items[l.steps.items.len - 1].metrics;
        space += previous.advance_x - previous.right + m.left;
    }
    l.steps.append(allocator, .{ .x = l.metrics.advance_x, .y = l.metrics.advance_y, .advance_x = m.advance_x, .advance_y = m.advance_y, .spacing = space, .orderer = orderer, .metrics = m }) catch return no_memory;
    l.ordering_space = space;
    l.last_attribute = attr;
    appendMetrics(&l.metrics, m, l.steps.items.len == 1);
    l.cursor = 0;
    return 0;
}
fn lineSpace(handle: usize, advance: ?*f32, head: ?*f32, inline_space: ?*f32, tail: ?*f32) callconv(abi.guest) i32 {
    for ([_]?*f32{ head, inline_space, tail, advance }) |p| if (p != null and !out(f32, p)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    const l = findLine(handle) orelse return invalid;
    if (head) |p| p.* = if (l.steps.items.len != 0) l.steps.items[0].metrics.left else 0;
    if (tail) |p| {
        const last = if (l.steps.items.len != 0) l.steps.items[l.steps.items.len - 1].metrics else Metrics{};
        p.* = last.advance_x - last.right;
    }
    if (inline_space) |p| p.* = l.ordering_space;
    if (advance) |p| p.* = l.metrics.advance_x;
    return 0;
}
fn lineStep(handle: usize) callconv(abi.guest) ?*const LineStep {
    mutex.lock();
    defer mutex.unlock();
    const l = findLine(handle) orelse return null;
    if (l.cursor != 0 and l.cursor <= l.steps.items.len) {
        // The caller may adjust the returned step before requesting the next.
        l.render_metrics.advance_x = l.step.x + l.step.adjust_x;
        l.render_metrics.advance_y = l.step.y + l.step.adjust_y;
        appendMetrics(&l.render_metrics, l.step.metrics, l.cursor == 1);
    } else if (l.cursor == 0) l.render_metrics = .{};
    if (l.cursor >= l.steps.items.len) {
        l.cursor = l.steps.items.len + 1;
        return null;
    }
    const index = l.cursor;
    l.cursor += 1;
    l.step = l.steps.items[index];
    l.step.x = l.render_metrics.advance_x;
    l.step.y = l.render_metrics.advance_y;
    l.step.spacing = if (l.ordering_space != 0) l.step.spacing / l.ordering_space else 0;
    return &l.step;
}
fn lineMetrics(handle: usize, output: ?*Metrics) callconv(abi.guest) i32 {
    if (!out(Metrics, output)) return invalid;
    mutex.lock();
    defer mutex.unlock();
    output.?.* = (findLine(handle) orelse return invalid).render_metrics;
    return 0;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceFontCreateString", .function = trace.wrap("sceFontCreateString", &createString), .expect_id = "MO24vDhmS4E" },
    .{ .name = "sceFontTextSourceInit", .function = trace.wrap("sceFontTextSourceInit", &sourceInit), .expect_id = "oaJ1BpN2FQk" },
    .{ .name = "sceFontCharacterGetTextFontCode", .function = trace.wrap("sceFontCharacterGetTextFontCode", &charCode), .expect_id = "zN3+nuA0SFQ" },
    .{ .name = "sceFontWritingLineClear", .function = trace.wrap("sceFontWritingLineClear", &clearLine), .expect_id = "1+DgKL0haWQ" },
    .{ .name = "sceFontWritingGetRenderMetrics", .function = trace.wrap("sceFontWritingGetRenderMetrics", &writingMetrics), .expect_id = "fljdejMcG1c" },
    .{ .name = "sceFontStringGetWritingForm", .function = trace.wrap("sceFontStringGetWritingForm", &stringForm), .expect_id = "o1vIEHeb6tw" },
    .{ .name = "sceFontStringRefersTextCharacters", .function = trace.wrap("sceFontStringRefersTextCharacters", &textChars), .expect_id = "Avv7OApgCJk" },
    .{ .name = "sceFontCharacterRefersTextNext", .function = trace.wrap("sceFontCharacterRefersTextNext", &nextChar), .expect_id = "BkjBP+YC19w" },
    .{ .name = "sceFontTextSourceSetWritingForm", .function = trace.wrap("sceFontTextSourceSetWritingForm", &sourceForm), .expect_id = "OqQKX0h5COw" },
    .{ .name = "sceFontStringRefersRenderCharacters", .function = trace.wrap("sceFontStringRefersRenderCharacters", &renderChars), .expect_id = "hq5LffQjz-s" },
    .{ .name = "sceFontDestroyString", .function = trace.wrap("sceFontDestroyString", &destroyString), .expect_id = "SSCaczu2aMQ" },
    .{ .name = "sceFontWritingLineWritesOrder", .function = trace.wrap("sceFontWritingLineWritesOrder", &lineOrder), .expect_id = "wyKFUOWdu3Q" },
    .{ .name = "sceFontCharacterGetBidiLevel", .function = trace.wrap("sceFontCharacterGetBidiLevel", &bidiLevel), .expect_id = "6DFUkCwQLa8" },
    .{ .name = "sceFontDestroyWritingLine", .function = trace.wrap("sceFontDestroyWritingLine", &destroyLine), .expect_id = "PEjv7CVDRYs" },
    .{ .name = "sceFontWritingLineGetRenderMetrics", .function = trace.wrap("sceFontWritingLineGetRenderMetrics", &lineMetrics), .expect_id = "nlU2VnfpqTM" },
    .{ .name = "sceFontWritingInit", .function = trace.wrap("sceFontWritingInit", &writingInit), .expect_id = "fD5rqhEXKYQ" },
    .{ .name = "sceFontWritingRefersRenderStep", .function = trace.wrap("sceFontWritingRefersRenderStep", &writingStep), .expect_id = "W-2WOXEHGck" },
    .{ .name = "sceFontTextSourceSetDefaultFont", .function = trace.wrap("sceFontTextSourceSetDefaultFont", &sourceFont), .expect_id = "eCRMCSk96NU" },
    .{ .name = "sceFontWritingLineGetOrderingSpace", .function = trace.wrap("sceFontWritingLineGetOrderingSpace", &lineSpace), .expect_id = "JQKWIsS9joE" },
    .{ .name = "sceFontCharacterLooksWhiteSpace", .function = trace.wrap("sceFontCharacterLooksWhiteSpace", &charWhitespace), .expect_id = "SaRlqtqaCew" },
    .{ .name = "sceFontWritingLineRefersRenderStep", .function = trace.wrap("sceFontWritingLineRefersRenderStep", &lineStep), .expect_id = "+FYcYefsVX0" },
    .{ .name = "sceFontCharacterGetTextOrder", .function = trace.wrap("sceFontCharacterGetTextOrder", &charOrder), .expect_id = "mxgmMj-Mq-o" },
    .{ .name = "sceFontWritingRefersRenderStepCharacter", .function = trace.wrap("sceFontWritingRefersRenderStepCharacter", &writingChar), .expect_id = "f4Onl7efPEY" },
    .{ .name = "sceFontCreateWritingLine", .function = trace.wrap("sceFontCreateWritingLine", &createLine), .expect_id = "7rogx92EEyc" },
    .{ .name = "sceFontStringGetTerminateCode", .function = trace.wrap("sceFontStringGetTerminateCode", &terminateCode), .expect_id = "ObkDGDBsVtw" },
};

fn imported(comptime name: []const u8, comptime T: type) T {
    inline for (font.exports) |entry| if (comptime std.mem.eql(u8, entry.name, name)) return @ptrCast(entry.function);
    @compileError("missing font export");
}

test "font text UTF-8 runs use real advances and preserve caller order" {
    font.reset();
    defer font.reset();
    const create = imported("sceFontCreateLibrary", *const fn (usize, usize, *usize) callconv(abi.guest) i32);
    const open = imported("sceFontOpenFontSet", *const fn (usize, u32, u32, usize, *usize) callconv(abi.guest) i32);
    var library: usize = 0;
    var face: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), create(0, 0, &library));
    try std.testing.expectEqual(@as(i32, 0), open(library, 0, 0, 0, &face));
    const text = "Wi \xc3\xa9";
    var source = Source{};
    var handle: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), sourceInit(&source, @intFromPtr(text.ptr), text.len, 0, 0));
    try std.testing.expectEqual(@as(u64, 0x1000000f04), source.magic);
    try std.testing.expectEqual(source.start, source.reserved[0]);
    try std.testing.expectEqual(source.end, source.reserved[1]);
    try std.testing.expectEqual(@as(i32, 0), sourceFont(&source, face));
    try std.testing.expectEqual(@as(i32, 0), createString(0, &source, null, &handle));
    var count: u32 = 0;
    const first = textChars(handle, &count);
    try std.testing.expectEqual(@as(u32, 4), count);
    var ch = first;
    for ([_]u32{ 'W', 'i', ' ', 0xe9 }, [_]usize{ 0, 1, 2, 3 }) |code, offset| {
        var actual: u32 = 0;
        var f: usize = 0;
        var order: usize = 0;
        try std.testing.expectEqual(@as(i32, 0), charCode(ch, &f, &actual));
        try std.testing.expectEqual(face, f);
        try std.testing.expectEqual(code, actual);
        try std.testing.expectEqual(if (code == ' ') @as(u32, ' ') else 0, charWhitespace(ch));
        try std.testing.expectEqual(@as(i32, 0), charOrder(ch, &order));
        try std.testing.expectEqual(@intFromPtr(text.ptr) + offset, order);
        ch = nextChar(ch);
    }
    try std.testing.expectEqual(@as(usize, 0), ch);
    var writing = std.mem.zeroes(Writing);
    try std.testing.expectEqual(@as(i32, 0), writingInit(&writing, handle, first));
    const wide = writingStep(&writing).?.advance_x;
    const narrow = writingStep(&writing).?.advance_x;
    try std.testing.expect(wide > narrow and narrow > 0);
    var letter: usize = 0;
    _ = writingChar(&writing, &letter);
    const components: *const Letter = @ptrFromInt(letter);
    try std.testing.expectEqual(@as(u32, 1), components.fields[3]);
    _ = writingStep(&writing);
    _ = writingStep(&writing);
    try std.testing.expect(writingStep(&writing) == null);
    var metrics: Metrics = .{};
    try std.testing.expectEqual(@as(i32, 0), writingMetrics(&writing, &metrics));
    try std.testing.expect(metrics.advance_x > wide + narrow and metrics.bottom > metrics.top);
    var line: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), createLine(0, 0x12, 0, &line));
    try std.testing.expectEqual(@as(i32, 0), lineOrder(line, 0xfa, &metrics, 123));
    try std.testing.expectEqual(@as(i32, 0), lineOrder(line, 0xfa, &metrics, 456));
    try std.testing.expectEqual(@as(usize, 123), lineStep(line).?.orderer);
    const second = lineStep(line).?;
    try std.testing.expectEqual(@as(usize, 456), second.orderer);
    try std.testing.expectEqual(metrics.advance_x, second.x);
    try std.testing.expect(lineStep(line) == null);
    try std.testing.expectEqual(@as(i32, 0), destroyLine(&line));
    try std.testing.expectEqual(@as(i32, 0), destroyString(&handle));
    try std.testing.expectEqual(@as(usize, 0), nextChar(first));
    try std.testing.expect(writingStep(&writing) == null);
}

test "font line ordering spaces preserve ABI order and caller adjustments" {
    reset();
    defer reset();
    var handle: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), createLine(0, 0x12, 0, &handle));
    const first = Metrics{ .advance_x = 12, .left = 2, .right = 9, .top = -8, .bottom = 1 };
    const second = Metrics{ .advance_x = 7, .left = 1, .right = 6, .top = -6, .bottom = 2 };
    try std.testing.expectEqual(@as(i32, 0), lineOrder(handle, 0x800000fa, &first, 1));
    try std.testing.expectEqual(@as(i32, 0), lineOrder(handle, 0xfa, &second, 2));
    var advance: f32 = -1;
    var head: f32 = -1;
    var inside: f32 = -1;
    var tail: f32 = -1;
    try std.testing.expectEqual(@as(i32, 0), lineSpace(handle, &advance, &head, &inside, &tail));
    try std.testing.expectEqual(@as(f32, 19), advance);
    try std.testing.expectEqual(@as(f32, 2), head);
    try std.testing.expectEqual(@as(f32, 4), inside);
    try std.testing.expectEqual(@as(f32, 1), tail);
    @constCast(lineStep(handle).?).adjust_x = 3;
    const next = lineStep(handle).?;
    try std.testing.expectEqual(@as(f32, 15), next.x);
    try std.testing.expectEqual(@as(f32, 1), next.spacing);
    try std.testing.expect(lineStep(handle) == null);
    var metrics: Metrics = .{};
    try std.testing.expectEqual(@as(i32, 0), lineMetrics(handle, &metrics));
    try std.testing.expectEqual(@as(f32, 22), metrics.advance_x);
    try std.testing.expectEqual(@as(f32, 5), metrics.left);
    try std.testing.expectEqual(@as(f32, 21), metrics.right);
}

test "font text parser callback receives the source and controls termination" {
    const Probe = struct {
        calls: u32 = 0,
        fail: bool = false,
        fn start(_: ?*anyopaque, _: threading.StartRequest) threading.BackendError!void {
            return error.StartFailed;
        }
        fn call(raw: ?*anyopaque, request: threading.GuestCall) threading.BackendError!u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const source: *Source = @ptrFromInt(request.arguments[0]);
            const order: *usize = @ptrFromInt(request.arguments[1]);
            const result: *ParseResult = @ptrFromInt(request.arguments[2]);
            self.calls += 1;
            if (self.fail) {
                result.code = 7; // A non-error code must not escape as success.
                return 0xffffffff;
            }
            order.* = source.current;
            if (source.current == source.start) {
                result.* = .{ .font = source.default_font, .code = 'A' };
                source.current += 2;
                return 1;
            }
            result.code = '\n';
            return 0;
        }
    };
    reset();
    defer reset();
    var address_space = try memory.AddressSpace.init(std.testing.allocator);
    defer address_space.deinit();
    var registry = @import("loader").TlsRegistry{};
    defer registry.deinit(std.testing.allocator);
    var manager = threading.Manager{};
    manager.init(std.testing.allocator, &address_space, &registry);
    defer manager.deinit();
    var probe = Probe{};
    manager.setBackend(.{ .context = &probe, .start_fn = Probe.start, .call_fn = Probe.call });
    threading.attachManager(&manager);
    defer threading.attachManager(null);
    var source = Source{};
    var handle: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), sourceInit(&source, 0x1234, 0, 0x5678, 0));
    try std.testing.expectEqual(@as(usize, 0), source.end);
    try std.testing.expectEqual(@as(i32, 0), sourceFont(&source, 77));
    try std.testing.expectEqual(@as(i32, 0), createString(0, &source, null, &handle));
    try std.testing.expectEqual(@as(u32, 2), probe.calls);
    try std.testing.expectEqual(@as(u32, '\n'), terminateCode(handle));
    var count: u32 = 0;
    const character = textChars(handle, &count);
    var code: u32 = 0;
    var face: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), charCode(character, &face, &code));
    try std.testing.expectEqual(@as(usize, 77), face);
    try std.testing.expectEqual(@as(u32, 'A'), code);
    try std.testing.expectEqual(@as(i32, 0), destroyString(&handle));
    probe.fail = true;
    handle = 99;
    try std.testing.expectEqual(invalid, createString(0, &source, null, &handle));
    try std.testing.expectEqual(@as(usize, 0), handle);
}
