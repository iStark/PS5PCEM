// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The firmware JSON document model and parser.
//!
//! Titles read their own configuration through this library, so the entry
//! points are C++ member functions rather than plain calls: constructors,
//! destructors, assignment and subscript, each receiving the object as its
//! first argument.
//!
//! The objects themselves belong to the title. It allocates them on its stack
//! or heap at a size its own headers decided, and this implementation never
//! writes into that memory: doing so would mean assuming a layout nobody here
//! can verify. Each live object is instead identified by its address, and the
//! document it stands for is held on this side. A constructor binds an
//! address, a destructor releases it, and copy construction and assignment
//! bind a second address to a copy of the same document — which is why they
//! must be honoured rather than treated as no-ops.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");

/// `SCE_JSON_ERROR_INVALID_PARAM`, returned for text the grammar rejects.
const error_invalid_param: i32 = @bitCast(@as(u32, 0x80AA_0002));

/// The value kinds the library distinguishes, in the order its own
/// `ValueType` enumeration uses.
pub const ValueType = enum(u32) {
    null_value = 0,
    boolean = 1,
    integer = 2,
    real = 3,
    string = 4,
    array = 5,
    object = 6,
};

/// How many documents may be live at once.
///
/// A title holds a handful: the document it parsed and the values it is
/// walking through. The bound is fixed so that a leaked object cannot grow
/// this table without limit, and reaching it degrades to an empty value
/// rather than to a failure the title cannot interpret.
const maximum_nodes: usize = 4096;
const maximum_bindings: usize = 4096;
/// Addresses handed back for values a title only borrows.
const maximum_borrowed: usize = 1024;

const Node = struct {
    kind: ValueType = .null_value,
    boolean: bool = false,
    integer: i64 = 0,
    real: f64 = 0,
    /// Index into `text_storage`, with `text_length` bytes.
    text_start: u32 = 0,
    text_length: u32 = 0,
    /// First child index, or `no_child`. Children form a singly linked chain
    /// so that a document of any shape fits one flat table.
    first_child: u32 = no_child,
    next_sibling: u32 = no_child,
    /// Member name for an object entry, stored like any other text.
    name_start: u32 = 0,
    name_length: u32 = 0,
    used: bool = false,
};

const no_child: u32 = std.math.maxInt(u32);

const Binding = struct {
    address: u64 = 0,
    node: u32 = no_child,
};

var nodes: [maximum_nodes]Node = @splat(.{});
var bindings: [maximum_bindings]Binding = @splat(.{});
var borrowed_slots: [maximum_borrowed]u64 = @splat(0);
var borrowed_next: usize = 0;
var text_storage: [256 * 1024]u8 = @splat(0);
var text_used: u32 = 0;
var state_lock: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (state_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    state_lock.store(false, .release);
}

fn allocateNode() ?u32 {
    for (&nodes, 0..) |*node, index| {
        if (node.used) continue;
        node.* = .{ .used = true };
        return @intCast(index);
    }
    return null;
}

fn releaseNode(index: u32) void {
    if (index == no_child or index >= nodes.len) return;
    var child = nodes[index].first_child;
    while (child != no_child) {
        const following = nodes[child].next_sibling;
        releaseNode(child);
        child = following;
    }
    nodes[index] = .{};
}

fn storeText(text: []const u8) ?struct { start: u32, length: u32 } {
    if (text.len > std.math.maxInt(u32)) return null;
    if (text_used + text.len > text_storage.len) return null;
    const start = text_used;
    @memcpy(text_storage[start..][0..text.len], text);
    text_used += @intCast(text.len);
    return .{ .start = start, .length = @intCast(text.len) };
}

fn nodeText(node: Node) []const u8 {
    return text_storage[node.text_start..][0..node.text_length];
}

fn nodeName(node: Node) []const u8 {
    return text_storage[node.name_start..][0..node.name_length];
}

fn bindingFor(address: u64) ?*Binding {
    if (address == 0) return null;
    for (&bindings) |*binding| {
        if (binding.address == address) return binding;
    }
    return null;
}

fn bind(address: u64, node: u32) void {
    if (address == 0) return;
    if (bindingFor(address)) |existing| {
        releaseNode(existing.node);
        existing.node = node;
        return;
    }
    for (&bindings) |*binding| {
        if (binding.address != 0) continue;
        binding.* = .{ .address = address, .node = node };
        return;
    }
    releaseNode(node);
}

fn unbind(address: u64) void {
    const binding = bindingFor(address) orelse return;
    releaseNode(binding.node);
    binding.* = .{};
}

fn nodeAt(address: u64) ?u32 {
    const binding = bindingFor(address) orelse return null;
    if (binding.node == no_child) return null;
    return binding.node;
}

/// Hands out an address a title may hold as a reference to a value it does
/// not own. The slots cycle, which is enough for the borrow-and-read pattern
/// the subscript operators exist for.
fn borrowAddress(node: u32) u64 {
    const slot = &borrowed_slots[borrowed_next % borrowed_slots.len];
    borrowed_next += 1;
    const address = @intFromPtr(slot);
    bind(address, node);
    return address;
}

fn copyNode(source: u32) ?u32 {
    if (source == no_child) return null;
    const destination = allocateNode() orelse return null;
    var copy = nodes[source];
    copy.used = true;
    copy.first_child = no_child;
    copy.next_sibling = no_child;
    nodes[destination] = copy;

    var last: u32 = no_child;
    var child = nodes[source].first_child;
    while (child != no_child) : (child = nodes[child].next_sibling) {
        const child_copy = copyNode(child) orelse break;
        if (last == no_child) {
            nodes[destination].first_child = child_copy;
        } else {
            nodes[last].next_sibling = child_copy;
        }
        last = child_copy;
    }
    return destination;
}

// ---------------------------------------------------------------- parsing

const Parser = struct {
    text: []const u8,
    index: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.index < self.text.len) : (self.index += 1) {
            switch (self.text[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.index < self.text.len) self.text[self.index] else null;
    }

    fn expect(self: *Parser, byte: u8) bool {
        if (self.peek() != byte) return false;
        self.index += 1;
        return true;
    }

    fn literal(self: *Parser, word: []const u8) bool {
        if (self.text.len - self.index < word.len) return false;
        if (!std.mem.eql(u8, self.text[self.index..][0..word.len], word)) return false;
        self.index += word.len;
        return true;
    }

    /// Reads one string, resolving the escapes the grammar defines. A
    /// `\u` escape is decoded to UTF-8, including a surrogate pair, because
    /// the title receives text and not the encoding it arrived in.
    fn readString(self: *Parser, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !bool {
        if (!self.expect('"')) return false;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            self.index += 1;
            switch (byte) {
                '"' => return true,
                '\\' => {
                    if (self.index >= self.text.len) return false;
                    const escape = self.text[self.index];
                    self.index += 1;
                    switch (escape) {
                        '"' => try out.append(allocator, '"'),
                        '\\' => try out.append(allocator, '\\'),
                        '/' => try out.append(allocator, '/'),
                        'b' => try out.append(allocator, 0x08),
                        'f' => try out.append(allocator, 0x0c),
                        'n' => try out.append(allocator, '\n'),
                        'r' => try out.append(allocator, '\r'),
                        't' => try out.append(allocator, '\t'),
                        'u' => {
                            const first = self.readHex4() orelse return false;
                            var code_point: u21 = first;
                            if (first >= 0xd800 and first <= 0xdbff) {
                                if (!self.literal("\\u")) return false;
                                const second = self.readHex4() orelse return false;
                                if (second < 0xdc00 or second > 0xdfff) return false;
                                code_point = 0x10000 +
                                    ((@as(u21, first - 0xd800)) << 10) +
                                    (second - 0xdc00);
                            } else if (first >= 0xdc00 and first <= 0xdfff) {
                                return false;
                            }
                            var encoded: [4]u8 = undefined;
                            const length = std.unicode.utf8Encode(code_point, &encoded) catch return false;
                            try out.appendSlice(allocator, encoded[0..length]);
                        },
                        else => return false,
                    }
                },
                else => {
                    if (byte < 0x20) return false;
                    try out.append(allocator, byte);
                },
            }
        }
        return false;
    }

    fn readHex4(self: *Parser) ?u16 {
        if (self.text.len - self.index < 4) return null;
        var value: u16 = 0;
        for (self.text[self.index..][0..4]) |digit| {
            const nibble = std.fmt.charToDigit(digit, 16) catch return null;
            value = value * 16 + nibble;
        }
        self.index += 4;
        return value;
    }
};

fn parseValue(parser: *Parser, allocator: std.mem.Allocator) ?u32 {
    parser.skipSpace();
    const byte = parser.peek() orelse return null;
    const index = allocateNode() orelse return null;
    switch (byte) {
        'n' => {
            if (!parser.literal("null")) return null;
            nodes[index].kind = .null_value;
        },
        't' => {
            if (!parser.literal("true")) return null;
            nodes[index].kind = .boolean;
            nodes[index].boolean = true;
        },
        'f' => {
            if (!parser.literal("false")) return null;
            nodes[index].kind = .boolean;
            nodes[index].boolean = false;
        },
        '"' => {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(allocator);
            if (!(parser.readString(&text, allocator) catch false)) return null;
            const stored = storeText(text.items) orelse return null;
            nodes[index].kind = .string;
            nodes[index].text_start = stored.start;
            nodes[index].text_length = stored.length;
        },
        '[' => {
            parser.index += 1;
            nodes[index].kind = .array;
            parser.skipSpace();
            if (parser.peek() == ']') {
                parser.index += 1;
            } else {
                var last: u32 = no_child;
                while (true) {
                    const child = parseValue(parser, allocator) orelse return null;
                    if (last == no_child) nodes[index].first_child = child else nodes[last].next_sibling = child;
                    last = child;
                    parser.skipSpace();
                    if (parser.expect(',')) continue;
                    if (parser.expect(']')) break;
                    return null;
                }
            }
        },
        '{' => {
            parser.index += 1;
            nodes[index].kind = .object;
            parser.skipSpace();
            if (parser.peek() == '}') {
                parser.index += 1;
            } else {
                var last: u32 = no_child;
                while (true) {
                    parser.skipSpace();
                    var name: std.ArrayList(u8) = .empty;
                    defer name.deinit(allocator);
                    if (!(parser.readString(&name, allocator) catch false)) return null;
                    parser.skipSpace();
                    if (!parser.expect(':')) return null;
                    const child = parseValue(parser, allocator) orelse return null;
                    const stored = storeText(name.items) orelse return null;
                    nodes[child].name_start = stored.start;
                    nodes[child].name_length = stored.length;
                    if (last == no_child) nodes[index].first_child = child else nodes[last].next_sibling = child;
                    last = child;
                    parser.skipSpace();
                    if (parser.expect(',')) continue;
                    if (parser.expect('}')) break;
                    return null;
                }
            }
        },
        else => {
            const start = parser.index;
            if (parser.peek() == '-') parser.index += 1;
            var digits: usize = 0;
            var real = false;
            while (parser.index < parser.text.len) : (parser.index += 1) {
                switch (parser.text[parser.index]) {
                    '0'...'9' => digits += 1,
                    '.', 'e', 'E', '+', '-' => real = true,
                    else => break,
                }
            }
            if (digits == 0) return null;
            const text = parser.text[start..parser.index];
            if (real) {
                nodes[index].kind = .real;
                nodes[index].real = std.fmt.parseFloat(f64, text) catch return null;
                nodes[index].integer = @intFromFloat(@trunc(nodes[index].real));
            } else {
                nodes[index].kind = .integer;
                nodes[index].integer = std.fmt.parseInt(i64, text, 10) catch return null;
                nodes[index].real = @floatFromInt(nodes[index].integer);
            }
        },
    }
    return index;
}

/// Parses a complete document, which must be one value and nothing after it.
pub fn parseDocument(text: []const u8, allocator: std.mem.Allocator) ?u32 {
    var parser = Parser{ .text = text };
    const root = parseValue(&parser, allocator) orelse return null;
    parser.skipSpace();
    if (parser.index != parser.text.len) {
        releaseNode(root);
        return null;
    }
    return root;
}

fn findMember(node: u32, name: []const u8) ?u32 {
    if (node == no_child or nodes[node].kind != .object) return null;
    var child = nodes[node].first_child;
    while (child != no_child) : (child = nodes[child].next_sibling) {
        if (std.mem.eql(u8, nodeName(nodes[child]), name)) return child;
    }
    return null;
}

fn elementAt(node: u32, position: usize) ?u32 {
    if (node == no_child or nodes[node].kind != .array) return null;
    var child = nodes[node].first_child;
    var index: usize = 0;
    while (child != no_child) : (child = nodes[child].next_sibling) {
        if (index == position) return child;
        index += 1;
    }
    return null;
}

// ------------------------------------------------------------- guest ABI

fn guestText(pointer: ?[*:0]const u8) []const u8 {
    const text = pointer orelse return &.{};
    return std.mem.sliceTo(text, 0);
}

fn emptyNodeFor(address: u64, kind: ValueType) void {
    const index = allocateNode() orelse return;
    nodes[index].kind = kind;
    bind(address, index);
}

pub fn valueConstruct(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    emptyNodeFor(this, .null_value);
}

pub fn valueDestruct(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    unbind(this);
}

pub fn valueCopyAssign(this: u64, other: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    if (nodeAt(other)) |source| {
        if (copyNode(source)) |copy| bind(this, copy);
    } else {
        emptyNodeFor(this, .null_value);
    }
    return this;
}

pub fn objectConstruct(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    emptyNodeFor(this, .object);
}

pub fn objectCopyConstruct(this: u64, other: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    if (nodeAt(other)) |source| {
        if (copyNode(source)) |copy| {
            bind(this, copy);
            return;
        }
    }
    emptyNodeFor(this, .object);
}

pub fn objectDestruct(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    unbind(this);
}

pub fn stringConstructEmpty(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    emptyNodeFor(this, .string);
}

pub fn stringConstructFromText(this: u64, text: ?[*:0]const u8) callconv(abi.guest) void {
    lock();
    defer unlock();
    const index = allocateNode() orelse return;
    nodes[index].kind = .string;
    if (storeText(guestText(text))) |stored| {
        nodes[index].text_start = stored.start;
        nodes[index].text_length = stored.length;
    }
    bind(this, index);
}

pub fn stringDestruct(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    unbind(this);
}

/// Returns text the title may hold after the call, so it is terminated in
/// storage that outlives this function rather than on the stack.
pub fn stringCStr(this: u64) callconv(abi.guest) [*:0]const u8 {
    lock();
    defer unlock();
    const empty: [*:0]const u8 = "";
    const index = nodeAt(this) orelse return empty;
    const text = nodeText(nodes[index]);
    if (text.len == 0) return empty;
    // The stored bytes are not terminated; terminate a copy once.
    if (text_used + text.len + 1 > text_storage.len) return empty;
    const start = text_used;
    @memcpy(text_storage[start..][0..text.len], text);
    text_storage[start + text.len] = 0;
    text_used += @intCast(text.len + 1);
    return @ptrCast(&text_storage[start]);
}

pub fn stringLength(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    return nodes[index].text_length;
}

pub fn valueGetType(this: u64) callconv(abi.guest) u32 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return @intFromEnum(ValueType.null_value);
    return @intFromEnum(nodes[index].kind);
}

pub fn valueGetInteger(this: u64) callconv(abi.guest) i64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    return nodes[index].integer;
}

pub fn valueGetReal(this: u64) callconv(abi.guest) f64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    return nodes[index].real;
}

pub fn valueGetBoolean(this: u64) callconv(abi.guest) bool {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return false;
    return nodes[index].boolean;
}

/// `getString` hands back a reference to the value's own text, so the title
/// receives an address it can call `c_str` on.
pub fn valueGetString(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowAddress(no_child);
    return borrowAddress(index);
}

pub fn valueSubscriptName(this: u64, name: ?[*:0]const u8) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowedNull();
    const member = findMember(index, guestText(name)) orelse return borrowedNull();
    return borrowAddress(member);
}

pub fn valueSubscriptIndex(this: u64, position: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowedNull();
    const element = elementAt(index, position) orelse return borrowedNull();
    return borrowAddress(element);
}

pub fn objectSubscript(this: u64, name_object: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowedNull();
    const name_index = nodeAt(name_object) orelse return borrowedNull();
    const name = nodeText(nodes[name_index]);
    if (findMember(index, name)) |member| return borrowAddress(member);

    // Subscript on an object creates the member it names, as the C++
    // container it mirrors does.
    const created = allocateNode() orelse return borrowedNull();
    if (storeText(name)) |stored| {
        nodes[created].name_start = stored.start;
        nodes[created].name_length = stored.length;
    }
    var last = nodes[index].first_child;
    if (last == no_child) {
        nodes[index].first_child = created;
    } else {
        while (nodes[last].next_sibling != no_child) last = nodes[last].next_sibling;
        nodes[last].next_sibling = created;
    }
    return borrowAddress(created);
}

fn borrowedNull() u64 {
    const index = allocateNode() orelse return 0;
    nodes[index].kind = .null_value;
    return borrowAddress(index);
}

pub fn arraySize(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    if (nodes[index].kind != .array) return 0;
    var count: u64 = 0;
    var child = nodes[index].first_child;
    while (child != no_child) : (child = nodes[child].next_sibling) count += 1;
    return count;
}

pub fn parserParse(value: u64, text: ?[*:0]const u8, length: u64) callconv(abi.guest) i32 {
    lock();
    defer unlock();
    const source = text orelse return error_invalid_param;
    const bounded = std.mem.sliceTo(source, 0);
    const span = if (length == 0 or length > bounded.len) bounded else bounded[0..length];

    var buffer: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const root = parseDocument(span, fixed.allocator()) orelse return error_invalid_param;
    bind(value, root);
    return errno.ok;
}


test "a document parses into the values it describes" {
    lock();
    for (&nodes) |*node| node.* = .{};
    for (&bindings) |*binding| binding.* = .{};
    text_used = 0;
    unlock();

    var buffer: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const root = parseDocument(
        \\{"name":"rex","size":42,"scale":1.5,"live":true,"tags":["a","b"],"none":null}
    , fixed.allocator()) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(ValueType.object, nodes[root].kind);
    const name = findMember(root, "name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("rex", nodeText(nodes[name]));
    const size = findMember(root, "size") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 42), nodes[size].integer);
    const scale = findMember(root, "scale") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 1.5), nodes[scale].real);
    const live = findMember(root, "live") orelse return error.TestUnexpectedResult;
    try std.testing.expect(nodes[live].boolean);
    const none = findMember(root, "none") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ValueType.null_value, nodes[none].kind);

    const tags = findMember(root, "tags") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ValueType.array, nodes[tags].kind);
    const second = elementAt(tags, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", nodeText(nodes[second]));
}

test "escapes decode and malformed documents are refused" {
    lock();
    for (&nodes) |*node| node.* = .{};
    text_used = 0;
    unlock();

    var buffer: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    const escaped = parseDocument("\"a\\nb\\u00e9\\ud83d\\ude00\"", fixed.allocator()) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a\nb\u{e9}\u{1f600}", nodeText(nodes[escaped]));

    // Text after the document, an unterminated string, a lone surrogate and a
    // bare word are all refused rather than half accepted.
    try std.testing.expect(parseDocument("{} trailing", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("\"unterminated", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("\"\\ud83d\"", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("{\"a\":}", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("nope", fixed.allocator()) == null);
}
