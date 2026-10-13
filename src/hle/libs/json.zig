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
    unsigned_integer = 3,
    real = 4,
    string = 5,
    array = 6,
    object = 7,
};

// Nodes live in stable chunks: growing the registry must not invalidate
// references previously returned to guest code. Released nodes are reused.
const nodes_per_chunk = 256;
const storage_allocator = std.heap.smp_allocator;

const Node = struct {
    kind: ValueType = .null_value,
    boolean: bool = false,
    integer: i64 = 0,
    real: f64 = 0,
    /// Reference-counted text entry, with `text_length` bytes.
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
    borrowed_slot: u64 = 0,
    next_free: u32 = no_child,
};

const no_child: u32 = std.math.maxInt(u32);

var node_chunks: std.ArrayList(*[nodes_per_chunk]Node) = .empty;
var node_count: u32 = 0;
var free_node: u32 = no_child;
var bindings: std.AutoHashMapUnmanaged(u64, u32) = .empty;
var borrowed_indices: std.AutoHashMapUnmanaged(u64, u32) = .empty;
const null_reference: u64 = 0;
const zero_integer: i64 = 0;
const zero_real: f64 = 0;
const false_boolean: bool = false;
const TextEntry = struct {
    bytes: ?[:0]u8 = null,
    references: usize = 0,
    next_free: u32 = no_child,
};
var texts: std.ArrayList(TextEntry) = .empty;
var free_text: u32 = no_child;
var text_used: usize = 0;
var live_nodes: usize = 0;

fn getNode(index: u32) *Node {
    return &node_chunks.items[index / nodes_per_chunk][index % nodes_per_chunk];
}

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
    const index = if (free_node != no_child) reuse: {
        const index = free_node;
        free_node = getNode(index).next_free;
        break :reuse index;
    } else fresh: {
        if (node_count == no_child) return null;
        if (node_count % nodes_per_chunk == 0) {
            const chunk = storage_allocator.create([nodes_per_chunk]Node) catch return null;
            node_chunks.append(storage_allocator, chunk) catch {
                storage_allocator.destroy(chunk);
                return null;
            };
        }
        const index = node_count;
        node_count += 1;
        borrowed_indices.put(storage_allocator, @intFromPtr(&getNode(index).borrowed_slot), index) catch {
            node_count -= 1;
            if (node_count % nodes_per_chunk == 0) storage_allocator.destroy(node_chunks.pop().?);
            return null;
        };
        break :fresh index;
    };
    getNode(index).* = .{ .used = true };
    live_nodes += 1;
    return index;
}

fn recycleNode(index: u32) void {
    getNode(index).* = .{ .next_free = free_node };
    free_node = index;
    live_nodes -= 1;
}

fn releaseText(index: u32, length: u32) void {
    if (length == 0) return;
    const entry = &texts.items[index];
    entry.references -= 1;
    if (entry.references != 0) return;
    const bytes = entry.bytes.?;
    text_used -= bytes.len + 1;
    storage_allocator.free(bytes);
    entry.* = .{ .next_free = free_text };
    free_text = index;
}

fn retainText(index: u32, length: u32) void {
    if (length != 0) texts.items[index].references += 1;
}

fn releaseNode(index: u32) void {
    if (index == no_child or index >= node_count or !getNode(index).used) return;
    var child = getNode(index).first_child;
    while (child != no_child) {
        const following = getNode(child).next_sibling;
        releaseNode(child);
        child = following;
    }
    releaseText(getNode(index).text_start, getNode(index).text_length);
    releaseText(getNode(index).name_start, getNode(index).name_length);
    recycleNode(index);
}

fn storeText(text: []const u8) ?struct { start: u32, length: u32 } {
    if (text.len == 0) return .{ .start = 0, .length = 0 };
    if (text.len > std.math.maxInt(u32)) return null;
    const bytes = storage_allocator.dupeZ(u8, text) catch return null;
    const index = if (free_text != no_child) reuse: {
        const index = free_text;
        free_text = texts.items[index].next_free;
        break :reuse index;
    } else fresh: {
        if (texts.items.len == no_child) {
            storage_allocator.free(bytes);
            return null;
        }
        texts.append(storage_allocator, .{}) catch {
            storage_allocator.free(bytes);
            return null;
        };
        break :fresh @as(u32, @intCast(texts.items.len - 1));
    };
    texts.items[index] = .{ .bytes = bytes, .references = 1 };
    text_used += bytes.len + 1;
    return .{ .start = index, .length = @intCast(text.len) };
}

fn nodeText(value: Node) []const u8 {
    return if (value.text_length == 0) "" else texts.items[value.text_start].bytes.?;
}

fn nodeName(value: Node) []const u8 {
    return if (value.name_length == 0) "" else texts.items[value.name_start].bytes.?;
}

fn bind(address: u64, value: u32) void {
    if (address == 0 or address == @intFromPtr(&null_reference)) {
        releaseNode(value);
        return;
    }
    if (borrowedIndex(address)) |index| {
        if (index == value) return;
        // Keep the member identity while replacing its owned payload.
        const old = getNode(index).*;
        retainText(old.name_start, old.name_length);
        releaseNode(index);
        // releaseNode put index at the head of the free list; reclaim it.
        free_node = getNode(index).next_free;
        live_nodes += 1;
        releaseText(getNode(value).name_start, getNode(value).name_length);
        getNode(index).* = getNode(value).*;
        getNode(index).next_sibling = old.next_sibling;
        getNode(index).name_start = old.name_start;
        getNode(index).name_length = old.name_length;
        recycleNode(value); // Payload ownership moved to index.
        return;
    }
    const entry = bindings.getOrPut(storage_allocator, address) catch {
        releaseNode(value);
        return;
    };
    if (entry.found_existing) releaseNode(entry.value_ptr.*);
    entry.value_ptr.* = value;
}

fn unbind(address: u64) void {
    const entry = bindings.fetchRemove(address) orelse return;
    releaseNode(entry.value);
}

fn nodeAt(address: u64) ?u32 {
    if (address == 0 or address == @intFromPtr(&null_reference)) return null;
    if (borrowedIndex(address)) |index| return if (getNode(index).used) index else null;
    return bindings.get(address);
}

fn borrowedIndex(address: u64) ?u32 {
    return borrowed_indices.get(address);
}

/// The borrowed reference remains stable until the owning document changes.
fn borrowAddress(index: u32) u64 {
    if (index == no_child) return @intFromPtr(&null_reference);
    return @intFromPtr(&getNode(index).borrowed_slot);
}

pub fn reset() void {
    lock();
    defer unlock();
    for (texts.items) |entry| if (entry.bytes) |bytes| storage_allocator.free(bytes);
    texts.deinit(storage_allocator);
    texts = .empty;
    for (node_chunks.items) |chunk| storage_allocator.destroy(chunk);
    node_chunks.deinit(storage_allocator);
    node_chunks = .empty;
    bindings.deinit(storage_allocator);
    bindings = .empty;
    borrowed_indices.deinit(storage_allocator);
    borrowed_indices = .empty;
    node_count = 0;
    free_node = no_child;
    free_text = no_child;
    text_used = 0;
    live_nodes = 0;
}

fn copyNode(source: u32) ?u32 {
    if (source == no_child) return null;
    const destination = allocateNode() orelse return null;
    var copy = getNode(source).*;
    retainText(copy.text_start, copy.text_length);
    retainText(copy.name_start, copy.name_length);
    copy.used = true;
    copy.first_child = no_child;
    copy.next_sibling = no_child;
    getNode(destination).* = copy;

    var last: u32 = no_child;
    var child = getNode(source).*.first_child;
    while (child != no_child) : (child = getNode(child).*.next_sibling) {
        const child_copy = copyNode(child) orelse {
            releaseNode(destination);
            return null;
        };
        if (last == no_child) {
            getNode(destination).*.first_child = child_copy;
        } else {
            getNode(last).*.next_sibling = child_copy;
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
    var success = false;
    defer if (!success) releaseNode(index);
    switch (byte) {
        'n' => {
            if (!parser.literal("null")) return null;
            getNode(index).*.kind = .null_value;
        },
        't' => {
            if (!parser.literal("true")) return null;
            getNode(index).*.kind = .boolean;
            getNode(index).*.boolean = true;
        },
        'f' => {
            if (!parser.literal("false")) return null;
            getNode(index).*.kind = .boolean;
            getNode(index).*.boolean = false;
        },
        '"' => {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(allocator);
            if (!(parser.readString(&text, allocator) catch false)) return null;
            const stored = storeText(text.items) orelse return null;
            getNode(index).*.kind = .string;
            getNode(index).*.text_start = stored.start;
            getNode(index).*.text_length = stored.length;
        },
        '[' => {
            parser.index += 1;
            getNode(index).*.kind = .array;
            parser.skipSpace();
            if (parser.peek() == ']') {
                parser.index += 1;
            } else {
                var last: u32 = no_child;
                while (true) {
                    const child = parseValue(parser, allocator) orelse return null;
                    if (last == no_child) getNode(index).*.first_child = child else getNode(last).*.next_sibling = child;
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
            getNode(index).*.kind = .object;
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
                    const stored = storeText(name.items) orelse {
                        releaseNode(child);
                        return null;
                    };
                    getNode(child).*.name_start = stored.start;
                    getNode(child).*.name_length = stored.length;
                    if (last == no_child) getNode(index).*.first_child = child else getNode(last).*.next_sibling = child;
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
                getNode(index).*.kind = .real;
                getNode(index).*.real = std.fmt.parseFloat(f64, text) catch return null;
            } else {
                getNode(index).*.kind = .integer;
                getNode(index).*.integer = std.fmt.parseInt(i64, text, 10) catch blk: {
                    const unsigned = std.fmt.parseInt(u64, text, 10) catch return null;
                    getNode(index).*.kind = .unsigned_integer;
                    break :blk @bitCast(unsigned);
                };
            }
        },
    }
    success = true;
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
    if (node == no_child or getNode(node).*.kind != .object) return null;
    var child = getNode(node).*.first_child;
    while (child != no_child) : (child = getNode(child).*.next_sibling) {
        if (std.mem.eql(u8, nodeName(getNode(child).*), name)) return child;
    }
    return null;
}

fn elementAt(node: u32, position: usize) ?u32 {
    if (node == no_child or getNode(node).*.kind != .array) return null;
    var child = getNode(node).*.first_child;
    var index: usize = 0;
    while (child != no_child) : (child = getNode(child).*.next_sibling) {
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
    getNode(index).*.kind = kind;
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

pub fn valueSetType(this: u64, kind: u32) callconv(abi.guest) void {
    lock();
    defer unlock();
    emptyNodeFor(this, std.enums.fromInt(ValueType, kind) orelse .null_value);
}

pub fn valueSetInteger(this: u64, value: i64) callconv(abi.guest) void {
    lock();
    defer unlock();
    const index = allocateNode() orelse return;
    getNode(index).*.kind = .integer;
    getNode(index).*.integer = value;
    bind(this, index);
}

pub fn valueSetUnsigned(this: u64, value: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    const index = allocateNode() orelse return;
    getNode(index).*.kind = .unsigned_integer;
    getNode(index).*.integer = @bitCast(value);
    bind(this, index);
}

pub fn valueSetReal(this: u64, value: f64) callconv(abi.guest) void {
    lock();
    defer unlock();
    const index = allocateNode() orelse return;
    getNode(index).*.kind = .real;
    getNode(index).*.real = value;
    bind(this, index);
}

pub fn valueSetBoolean(this: u64, value: bool) callconv(abi.guest) void {
    lock();
    defer unlock();
    const index = allocateNode() orelse return;
    getNode(index).*.kind = .boolean;
    getNode(index).*.boolean = value;
    bind(this, index);
}

pub fn arrayConstruct(this: u64) callconv(abi.guest) void {
    lock();
    defer unlock();
    emptyNodeFor(this, .array);
}

pub fn arrayPushBack(this: u64, value: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return this;
    if (getNode(index).*.kind != .array) return this;
    const child = if (nodeAt(value)) |source| copyNode(source) orelse return this else allocateNode() orelse return this;
    var last = getNode(index).*.first_child;
    if (last == no_child) {
        getNode(index).*.first_child = child;
    } else {
        while (getNode(last).*.next_sibling != no_child) last = getNode(last).*.next_sibling;
        getNode(last).*.next_sibling = child;
    }
    return this;
}

pub fn arrayBack(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowedNull();
    if (getNode(index).*.kind != .array) return borrowedNull();
    var last = getNode(index).*.first_child;
    if (last == no_child) return borrowedNull();
    while (getNode(last).*.next_sibling != no_child) last = getNode(last).*.next_sibling;
    return borrowAddress(last);
}

// The firmware iterator occupies one pointer-sized word, including when
// returned through the C++ hidden result pointer. Keep a stable node reference
// in that word so ordinary guest copies preserve the iterator position.
pub fn arrayBegin(result: *u64, this: u64) callconv(abi.guest) *u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse {
        result.* = 0;
        return result;
    };
    const child = if (getNode(index).kind == .array) getNode(index).first_child else no_child;
    result.* = if (child == no_child) 0 else borrowAddress(child);
    return result;
}

pub fn arrayEnd(result: *u64, _: u64) callconv(abi.guest) *u64 {
    result.* = 0;
    return result;
}

pub fn arrayIteratorNext(this: *u64) callconv(abi.guest) *u64 {
    lock();
    defer unlock();
    const index = nodeAt(this.*) orelse {
        this.* = 0;
        return this;
    };
    const next = getNode(index).next_sibling;
    this.* = if (next == no_child) 0 else borrowAddress(next);
    return this;
}

pub fn arrayIteratorValue(this: *const u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this.*) orelse return borrowedNull();
    return borrowAddress(index);
}

pub fn iteratorNotEqual(this: *const u64, other: *const u64) callconv(abi.guest) bool {
    return this.* != other.*;
}

pub fn iteratorDestruct(_: *u64) callconv(abi.guest) void {
    // Iterators borrow their container's nodes and own no allocation.
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
    getNode(index).*.kind = .string;
    if (storeText(guestText(text))) |stored| {
        getNode(index).*.text_start = stored.start;
        getNode(index).*.text_length = stored.length;
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
    if (getNode(index).*.kind != .string or getNode(index).*.text_length == 0) return empty;
    return texts.items[getNode(index).*.text_start].bytes.?.ptr;
}

fn serializeQuoted(text: []const u8, output: *std.ArrayList(u8)) !void {
    const allocator = std.heap.page_allocator;
    try output.append(allocator, '"');
    for (text) |byte| switch (byte) {
        '"' => try output.appendSlice(allocator, "\\\""),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        else => if (byte < 0x20) {
            const hex = "0123456789abcdef";
            try output.appendSlice(allocator, &.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15] });
        } else try output.append(allocator, byte),
    };
    try output.append(allocator, '"');
}

fn serializeNode(index: u32, output: *std.ArrayList(u8)) error{OutOfMemory}!void {
    const allocator = std.heap.page_allocator;
    const node: Node = if (index == no_child) .{} else getNode(index).*;
    var number: [512]u8 = undefined;
    switch (node.kind) {
        .null_value => try output.appendSlice(allocator, "null"),
        .boolean => try output.appendSlice(allocator, if (node.boolean) "true" else "false"),
        .integer => try output.appendSlice(allocator, std.fmt.bufPrint(&number, "{d}", .{node.integer}) catch unreachable),
        .unsigned_integer => try output.appendSlice(allocator, std.fmt.bufPrint(&number, "{d}", .{@as(u64, @bitCast(node.integer))}) catch unreachable),
        .real => {
            // JSON has no representation for NaN or infinity.
            if (!std.math.isFinite(node.real)) {
                try output.appendSlice(allocator, "null");
            } else {
                const text = std.fmt.bufPrint(&number, "{d}", .{node.real}) catch unreachable;
                try output.appendSlice(allocator, text);
                if (std.mem.indexOfAny(u8, text, ".eE") == null) try output.appendSlice(allocator, ".0");
            }
        },
        .string => try serializeQuoted(nodeText(node), output),
        .array, .object => {
            try output.append(allocator, if (node.kind == .array) '[' else '{');
            var child = node.first_child;
            while (child != no_child) : (child = getNode(child).*.next_sibling) {
                if (child != node.first_child) try output.append(allocator, ',');
                if (node.kind == .object) {
                    try serializeQuoted(nodeName(getNode(child).*), output);
                    try output.append(allocator, ':');
                }
                try serializeNode(child, output);
            }
            try output.append(allocator, if (node.kind == .array) ']' else '}');
        },
    }
}

fn convertToString(this: u64, destination: u64, quote_string: bool) i32 {
    lock();
    defer unlock();
    const source = nodeAt(this) orelse no_child;
    if (!quote_string and source != no_child and getNode(source).*.kind == .string) {
        const copy = copyNode(source) orelse return error_invalid_param;
        bind(destination, copy);
        return errno.ok;
    }
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.heap.page_allocator);
    serializeNode(source, &output) catch return error_invalid_param;
    const index = allocateNode() orelse return error_invalid_param;
    const stored = storeText(output.items) orelse {
        releaseNode(index);
        return error_invalid_param;
    };
    getNode(index).*.kind = .string;
    getNode(index).*.text_start = stored.start;
    getNode(index).*.text_length = stored.length;
    bind(destination, index);
    return errno.ok;
}

/// toString returns a string value verbatim; serialize emits JSON including quotes.
pub fn valueToString(this: u64, destination: u64) callconv(abi.guest) void {
    _ = convertToString(this, destination, false);
}

pub fn valueSerialize(this: u64, destination: u64) callconv(abi.guest) i32 {
    return convertToString(this, destination, true);
}

pub fn stringLength(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    return getNode(index).*.text_length;
}

pub fn valueGetType(this: u64) callconv(abi.guest) u32 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return @intFromEnum(ValueType.null_value);
    return @intFromEnum(getNode(index).*.kind);
}

pub fn valueGetInteger(this: u64) callconv(abi.guest) *const i64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return &zero_integer;
    if (getNode(index).*.kind != .integer and getNode(index).*.kind != .unsigned_integer) return &zero_integer;
    return &getNode(index).*.integer;
}

pub fn valueGetReal(this: u64) callconv(abi.guest) *const f64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return &zero_real;
    if (getNode(index).*.kind != .real) return &zero_real;
    return &getNode(index).*.real;
}

pub fn valueGetBoolean(this: u64) callconv(abi.guest) *const bool {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return &false_boolean;
    if (getNode(index).*.kind != .boolean) return &false_boolean;
    return &getNode(index).*.boolean;
}

/// `getString` hands back a reference to the value's own text, so the title
/// receives an address it can call `c_str` on.
pub fn valueGetString(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowAddress(no_child);
    if (getNode(index).*.kind != .string) return borrowedNull();
    return borrowAddress(index);
}

pub fn valueGetArray(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowedNull();
    return if (getNode(index).*.kind == .array) borrowAddress(index) else borrowedNull();
}

pub fn valueGetObject(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return borrowedNull();
    return if (getNode(index).*.kind == .object) borrowAddress(index) else borrowedNull();
}

pub fn valueReferObject(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    if (getNode(index).*.kind == .null_value) getNode(index).*.kind = .object;
    return if (getNode(index).*.kind == .object) borrowAddress(index) else 0;
}

pub fn valueReferArray(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    if (getNode(index).*.kind == .null_value) getNode(index).*.kind = .array;
    return if (getNode(index).*.kind == .array) borrowAddress(index) else 0;
}

/// Unlike const subscript, referValue returns nullptr when the member is absent.
/// Titles use that distinction to choose defaults for optional properties.
pub fn valueReferName(this: u64, name_object: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    const name_index = nodeAt(name_object) orelse return 0;
    const member = findMember(index, nodeText(getNode(name_index).*)) orelse return 0;
    return borrowAddress(member);
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
    const name = nodeText(getNode(name_index).*);
    if (findMember(index, name)) |member| return borrowAddress(member);

    // Subscript on an object creates the member it names, as the C++
    // container it mirrors does.
    const created = allocateNode() orelse return borrowedNull();
    if (storeText(name)) |stored| {
        getNode(created).*.name_start = stored.start;
        getNode(created).*.name_length = stored.length;
    }
    var last = getNode(index).*.first_child;
    if (last == no_child) {
        getNode(index).*.first_child = created;
    } else {
        while (getNode(last).*.next_sibling != no_child) last = getNode(last).*.next_sibling;
        getNode(last).*.next_sibling = created;
    }
    return borrowAddress(created);
}

fn borrowedNull() u64 {
    return borrowAddress(no_child);
}

pub fn arraySize(this: u64) callconv(abi.guest) u64 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    if (getNode(index).*.kind != .array) return 0;
    var count: u64 = 0;
    var child = getNode(index).*.first_child;
    while (child != no_child) : (child = getNode(child).*.next_sibling) count += 1;
    return count;
}

/// Value::count counts array elements or object members; scalar values are empty.
/// Returning a status code here makes callers interpret it as a negative size.
pub fn valueCount(this: u64) callconv(abi.guest) i32 {
    lock();
    defer unlock();
    const index = nodeAt(this) orelse return 0;
    if (getNode(index).*.kind != .array and getNode(index).*.kind != .object) return 0;
    var count: i32 = 0;
    var child = getNode(index).*.first_child;
    while (child != no_child) : (child = getNode(child).*.next_sibling) count += 1;
    return count;
}

pub fn parserParse(value: u64, text: ?[*:0]const u8, length: u64) callconv(abi.guest) i32 {
    lock();
    defer unlock();
    const source = text orelse return error_invalid_param;
    const bounded = std.mem.sliceTo(source, 0);
    const span = if (length == 0 or length > bounded.len) bounded else bounded[0..length];

    const root = parseDocument(span, storage_allocator) orelse return error_invalid_param;
    bind(value, root);
    return errno.ok;
}

test "JSON documents grow beyond 4096 nodes and bindings while references and cleanup remain valid" {
    reset();
    defer reset();
    const source = "{\"isUsed\":true,\"attrs\":[{\"target\":\"JsA_PT_Effect1\",\"name\":\"colorScaleB\",\"value\":4.0}]}";
    const base: u64 = 0x45670000;
    try std.testing.expectEqual(@as(i32, 0), parserParse(base, source, source.len));
    const member = valueSubscriptName(base, "isUsed");
    const boolean = valueGetBoolean(member);
    const target = valueSubscriptName(valueSubscriptIndex(valueSubscriptName(base, "attrs"), 0), "target");
    const string_pointer = stringCStr(valueGetString(target));
    for (1..5000) |i| try std.testing.expectEqual(@as(i32, 0), parserParse(base + i * 32, source, source.len));
    try std.testing.expect(live_nodes > 4096);
    try std.testing.expectEqual(@as(u32, 5000), bindings.count());
    try std.testing.expect(text_used > 256 * 1024);
    try std.testing.expectEqual(member, valueSubscriptName(base, "isUsed"));
    try std.testing.expect(boolean.*);
    try std.testing.expectEqual(string_pointer, stringCStr(valueGetString(target)));
    try std.testing.expectEqualStrings("JsA_PT_Effect1", std.mem.span(string_pointer));
    const copy: u64 = base + 5000 * 32;
    _ = valueCopyAssign(copy, base);
    for (0..5000) |i| valueDestruct(base + i * 32);
    try std.testing.expect(valueGetBoolean(valueSubscriptName(copy, "isUsed")).*);
    const copied_target = valueSubscriptName(valueSubscriptIndex(valueSubscriptName(copy, "attrs"), 0), "target");
    try std.testing.expectEqualStrings("JsA_PT_Effect1", std.mem.span(stringCStr(valueGetString(copied_target))));
    const allocated_nodes = node_count;
    const active_nodes = live_nodes;
    const active_text = text_used;
    for (0..5000) |_| {
        try std.testing.expectEqual(error_invalid_param, parserParse(base, "{\"name\":[\"temporary\",{}", 0));
        try std.testing.expectEqual(active_nodes, live_nodes);
        try std.testing.expectEqual(active_text, text_used);
    }
    try std.testing.expectEqual(allocated_nodes, node_count);
    valueDestruct(copy);
    try std.testing.expectEqual(@as(usize, 0), live_nodes);
    try std.testing.expectEqual(@as(usize, 0), text_used);
    try std.testing.expectEqual(@as(u32, 0), bindings.count());
}

test "JSON missing-member reference stays null across assignments" {
    reset();
    defer reset();
    const root: u64 = 0x1234b000;
    const copy: u64 = 0x1234b100;
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, "{\"name\":\"dolphin_ring\"}", 0));
    const missing = valueSubscriptName(root, "priority");
    // The shared const null returned for a missing property must never become
    // a registry owner and poison defaults in unrelated documents.
    _ = valueCopyAssign(missing, root);
    valueSetInteger(missing, 42);
    objectConstruct(missing);
    try std.testing.expectEqual(@as(u32, 0), valueGetType(missing));
    _ = valueCopyAssign(copy, missing);
    try std.testing.expectEqual(@as(u32, 0), valueGetType(copy));
    try std.testing.expectEqual(@as(i32, 1), valueCount(root));
    try std.testing.expectEqualStrings("dolphin_ring", std.mem.span(stringCStr(valueSubscriptName(root, "name"))));
    valueDestruct(copy);
    valueDestruct(root);
    try std.testing.expectEqual(@as(usize, 0), live_nodes);
}

test "JSON toString retains animation names and serialization escapes nested values" {
    const root: u64 = 0x1234a000;
    const destination: u64 = 0x1234a100;
    const roundtrip: u64 = 0x1234a200;
    valueConstruct(root);
    defer valueDestruct(root);
    stringConstructEmpty(destination);
    defer stringDestruct(destination);
    valueConstruct(roundtrip);
    defer valueDestruct(roundtrip);
    const source = "{\"name\":\"intro_animation\",\"escaped\":\"a\\n\\\"\\\\\\u0001\",\"list\":[true,null,1.25,-7,18446744073709551615]}";
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, source, source.len));
    valueToString(valueSubscriptName(root, "name"), destination);
    const string_pointer = stringCStr(destination);
    try std.testing.expectEqualStrings("intro_animation", std.mem.span(string_pointer));
    const allocated_text = text_used;
    for (0..32768) |_| try std.testing.expectEqual(string_pointer, stringCStr(destination));
    try std.testing.expectEqual(allocated_text, text_used);
    try std.testing.expectEqual(@as(i32, 0), valueSerialize(root, destination));
    try std.testing.expectEqualStrings(source, std.mem.span(stringCStr(destination)));
    try std.testing.expectEqual(@as(i32, 0), parserParse(roundtrip, stringCStr(destination), stringLength(destination)));
    valueToString(valueSubscriptName(roundtrip, "escaped"), destination);
    try std.testing.expectEqualStrings("a\n\"\\\x01", std.mem.span(stringCStr(destination)));
    valueToString(valueSubscriptIndex(valueSubscriptName(roundtrip, "list"), 4), destination);
    try std.testing.expectEqualStrings("18446744073709551615", std.mem.span(stringCStr(destination)));
    try std.testing.expectEqual(@as(i32, 0), valueSerialize(valueSubscriptName(root, "name"), destination));
    try std.testing.expectEqualStrings("\"intro_animation\"", std.mem.span(stringCStr(destination)));
    // Both conversion paths support aliased source and destination.
    valueToString(destination, destination);
    try std.testing.expectEqualStrings("\"intro_animation\"", std.mem.span(stringCStr(destination)));
}

test "JSON value count reports members and array elements without counting scalars" {
    const root: u64 = 0x12345000;
    valueConstruct(root);
    defer valueDestruct(root);
    try std.testing.expectEqual(@as(i32, 0), valueCount(root));
    const source = "{\"list\":[1,2,3],\"nested\":{\"x\":true},\"text\":\"four\",\"empty\":[]}";
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, source, source.len));
    try std.testing.expectEqual(@as(i32, 4), valueCount(root));
    try std.testing.expectEqual(@as(i32, 3), valueCount(valueSubscriptName(root, "list")));
    try std.testing.expectEqual(@as(i32, 1), valueCount(valueSubscriptName(root, "nested")));
    try std.testing.expectEqual(@as(i32, 0), valueCount(valueSubscriptName(root, "text")));
    try std.testing.expectEqual(@as(i32, 0), valueCount(valueSubscriptName(root, "empty")));
    try std.testing.expectEqual(@as(i32, 0), valueCount(0));
}

test "JSON scalar getters return stable references with firmware type numbers" {
    const root: u64 = 0x12346000;
    valueConstruct(root);
    defer valueDestruct(root);
    const source = "{\"i\":-42,\"u\":18446744073709551615,\"r\":1.25,\"b\":true,\"s\":\"text\",\"a\":[],\"huge\":1e100}";
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, source, source.len));
    const integer = valueSubscriptName(root, "i");
    const unsigned = valueSubscriptName(root, "u");
    const real = valueSubscriptName(root, "r");
    const boolean = valueSubscriptName(root, "b");
    try std.testing.expectEqual(@as(u32, 7), valueGetType(root));
    try std.testing.expectEqual(@as(u32, 2), valueGetType(integer));
    try std.testing.expectEqual(@as(u32, 3), valueGetType(unsigned));
    try std.testing.expectEqual(@as(u32, 4), valueGetType(real));
    try std.testing.expectEqual(@as(u32, 1), valueGetType(boolean));
    try std.testing.expectEqual(@as(u32, 5), valueGetType(valueSubscriptName(root, "s")));
    try std.testing.expectEqual(@as(u32, 6), valueGetType(valueSubscriptName(root, "a")));
    const reference = valueGetInteger(integer);
    try std.testing.expectEqual(@as(i64, -42), reference.*);
    try std.testing.expectEqual(std.math.maxInt(u64), @as(u64, @bitCast(valueGetInteger(unsigned).*)));
    try std.testing.expectEqual(@as(f64, 1.25), valueGetReal(real).*);
    try std.testing.expect(valueGetBoolean(boolean).*);
    try std.testing.expectEqual(@as(f64, 1e100), valueGetReal(valueSubscriptName(root, "huge")).*);
    for (0..4096) |_| {
        try std.testing.expectEqual(integer, valueSubscriptName(root, "i"));
        try std.testing.expectEqual(@as(i64, -42), reference.*);
        try std.testing.expectEqual(@as(i64, 0), valueGetInteger(valueSubscriptName(root, "missing")).*);
    }
    try std.testing.expectEqual(@as(f64, 0), valueGetReal(integer).*);
    try std.testing.expect(!valueGetBoolean(real).*);
}

test "JSON mutable container references initialize null values and retain parent ownership" {
    reset();
    defer reset();
    const root: u64 = 0x1234c000;
    const element: u64 = 0x1234c100;
    const key: u64 = 0x1234c200;
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, "{\"list\":null,\"map\":null,\"sibling\":42}", 0));
    defer valueDestruct(root);
    valueSetInteger(element, 7);
    defer valueDestruct(element);
    stringConstructFromText(key, "answer");
    defer stringDestruct(key);
    const list = valueReferArray(valueSubscriptName(root, "list"));
    try std.testing.expect(list != 0);
    _ = arrayPushBack(list, element);
    try std.testing.expectEqual(@as(u64, 1), arraySize(valueGetArray(valueSubscriptName(root, "list"))));
    try std.testing.expectEqual(@as(i64, 7), valueGetInteger(valueSubscriptIndex(list, 0)).*);
    const map = valueReferObject(valueSubscriptName(root, "map"));
    try std.testing.expect(map != 0);
    valueSetInteger(objectSubscript(map, key), 9);
    try std.testing.expectEqual(@as(i64, 9), valueGetInteger(valueSubscriptName(valueSubscriptName(root, "map"), "answer")).*);
    valueDestruct(list);
    valueDestruct(map);
    try std.testing.expectEqual(@as(u64, 1), arraySize(list));
    try std.testing.expectEqual(@as(i64, 42), valueGetInteger(valueSubscriptName(root, "sibling")).*);
    try std.testing.expectEqual(@as(u64, 0), valueReferArray(valueSubscriptName(root, "missing")));
    try std.testing.expectEqual(@as(u64, 0), valueReferObject(valueSubscriptName(root, "missing")));
    try std.testing.expectEqual(@as(u32, 0), valueGetType(valueSubscriptName(root, "missing")));
}

test "JSON array iteration visits numeric elements and preserves copies and borrowed mutations" {
    reset();
    defer reset();
    const root: u64 = 0x1234d000;
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, "[1.25,2.5,3.75]", 0));
    defer valueDestruct(root);
    const array = valueGetArray(root);
    var current: u64 = undefined;
    var end: u64 = undefined;
    try std.testing.expectEqual(&current, arrayBegin(&current, array));
    try std.testing.expectEqual(&end, arrayEnd(&end, array));
    var copy = current;
    var count: usize = 0;
    const expected = [_]f64{ 1.25, 2.5, 3.75 };
    while (iteratorNotEqual(&current, &end)) : (count += 1) {
        try std.testing.expect(count < expected.len);
        const value = arrayIteratorValue(&current);
        try std.testing.expectEqual(expected[count], valueGetReal(value).*);
        if (count == 0) valueSetReal(value, 9.5);
        try std.testing.expectEqual(&current, arrayIteratorNext(&current));
    }
    try std.testing.expectEqual(expected.len, count);
    try std.testing.expectEqual(@as(f64, 9.5), valueGetReal(arrayIteratorValue(&copy)).*);
    iteratorDestruct(&copy);
    iteratorDestruct(&current);
    iteratorDestruct(&end);
    try std.testing.expectEqual(@as(u64, 3), arraySize(array));
    try std.testing.expectEqual(@as(f64, 9.5), valueGetReal(valueSubscriptIndex(root, 0)).*);
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, "[]", 0));
    _ = arrayBegin(&current, valueGetArray(root));
    _ = arrayEnd(&end, valueGetArray(root));
    try std.testing.expect(!iteratorNotEqual(&current, &end));
}

test "JSON assignment through a borrowed member preserves its parent and siblings" {
    const root: u64 = 0x12347000;
    const replacement: u64 = 0x12348000;
    valueConstruct(root);
    defer valueDestruct(root);
    valueConstruct(replacement);
    defer valueDestruct(replacement);
    const source = "{\"m\":2,\"n\":3}";
    try std.testing.expectEqual(@as(i32, 0), parserParse(root, source, source.len));
    try std.testing.expectEqual(@as(i32, 0), parserParse(replacement, "99", 2));
    const member = valueSubscriptName(root, "m");
    const reference = valueGetInteger(member);
    _ = valueCopyAssign(member, replacement);
    try std.testing.expectEqual(@as(i64, 99), reference.*);
    try std.testing.expectEqual(@as(i64, 99), valueGetInteger(valueSubscriptName(root, "m")).*);
    try std.testing.expectEqual(@as(i64, 3), valueGetInteger(valueSubscriptName(root, "n")).*);
    try std.testing.expectEqual(@as(i32, 2), valueCount(root));
    valueDestruct(member); // Borrowed references never destroy the parent's node.
    try std.testing.expectEqual(@as(i64, 99), valueGetInteger(member).*);
}

test "JSON optional property lookup distinguishes missing from null and container copies own their values" {
    const object: u64 = 0x12349000;
    const key: u64 = 0x12349100;
    const value: u64 = 0x12349200;
    const array: u64 = 0x12349300;
    const copy: u64 = 0x12349400;
    objectConstruct(object);
    defer objectDestruct(object);
    stringConstructFromText(key, "applyToAll");
    defer stringDestruct(key);
    valueConstruct(value);
    defer valueDestruct(value);
    arrayConstruct(array);
    defer valueDestruct(array);
    valueConstruct(copy);
    defer valueDestruct(copy);
    for (0..4096) |_| try std.testing.expectEqual(@as(u64, 0), valueReferName(object, key));
    try std.testing.expectEqual(@as(i32, 0), valueCount(object));
    const member = objectSubscript(object, key);
    try std.testing.expectEqual(member, valueReferName(object, key));
    try std.testing.expectEqual(@as(u32, 0), valueGetType(member));
    valueSetBoolean(member, true);
    try std.testing.expect(valueGetBoolean(valueReferName(object, key)).*);
    valueSetInteger(value, -7);
    _ = arrayPushBack(array, value);
    valueSetReal(value, 2.5);
    _ = arrayPushBack(array, value);
    _ = valueCopyAssign(copy, array);
    valueSetType(array, @intFromEnum(ValueType.array));
    try std.testing.expectEqual(@as(u64, 0), arraySize(array));
    try std.testing.expectEqual(@as(u64, 2), arraySize(valueGetArray(copy)));
    try std.testing.expectEqual(@as(i64, -7), valueGetInteger(valueSubscriptIndex(copy, 0)).*);
    try std.testing.expectEqual(@as(f64, 2.5), valueGetReal(arrayBack(copy)).*);
    valueSetUnsigned(value, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u32, 3), valueGetType(value));
    try std.testing.expectEqual(@as(i64, -1), valueGetInteger(value).*);
    try std.testing.expectEqual(@as(u64, 0), valueReferObject(value));
    try std.testing.expectEqual(@as(i32, 1), valueCount(valueGetObject(object)));
}

test "a document parses into the values it describes" {
    reset();
    defer reset();

    var buffer: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const root = parseDocument(
        \\{"name":"rex","size":42,"scale":1.5,"live":true,"tags":["a","b"],"none":null}
    , fixed.allocator()) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(ValueType.object, getNode(root).*.kind);
    const name = findMember(root, "name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("rex", nodeText(getNode(name).*));
    const size = findMember(root, "size") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 42), getNode(size).*.integer);
    const scale = findMember(root, "scale") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 1.5), getNode(scale).*.real);
    const live = findMember(root, "live") orelse return error.TestUnexpectedResult;
    try std.testing.expect(getNode(live).*.boolean);
    const none = findMember(root, "none") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ValueType.null_value, getNode(none).*.kind);

    const tags = findMember(root, "tags") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ValueType.array, getNode(tags).*.kind);
    const second = elementAt(tags, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", nodeText(getNode(second).*));
}

test "escapes decode and malformed documents are refused" {
    reset();
    defer reset();

    var buffer: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    const escaped = parseDocument("\"a\\nb\\u00e9\\ud83d\\ude00\"", fixed.allocator()) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a\nb\u{e9}\u{1f600}", nodeText(getNode(escaped).*));

    // Text after the document, an unterminated string, a lone surrogate and a
    // bare word are all refused rather than half accepted.
    try std.testing.expect(parseDocument("{} trailing", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("\"unterminated", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("\"\\ud83d\"", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("{\"a\":}", fixed.allocator()) == null);
    try std.testing.expect(parseDocument("nope", fixed.allocator()) == null);
}
