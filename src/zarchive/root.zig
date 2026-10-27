// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Pure-Zig reader for ZArchive (.zar) game dumps.
//!
//! Format: zstd-compressed 64KiB blocks with random access, a file tree with
//! case-insensitive paths, and a big-endian footer. Reimplemented from the
//! format behavior; titles mount read-only and stream without extracting.

const std = @import("std");

pub const block_size: usize = 64 * 1024;
const entries_per_record: usize = 16;
const footer_size: usize = 144;
const record_size: usize = 40;
const entry_size: usize = 16;
const magic: u32 = 0x169f52d6;
const version: u32 = 0x61bf3a01;
const cache_blocks: usize = 64;
const invalid_block: u64 = std.math.maxInt(u64);

pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    offset_records: []OffsetRecord,
    name_table: []u8,
    entries: []Entry,
    compressed_offset: u64,
    compressed_size: u64,
    cache_data: []u8,
    cache_index: [cache_blocks]u64,
    cache_tick: [cache_blocks]u64,
    clock: u64 = 0,
    comp_scratch: []u8,
    mutex: Lock = .{},

    const Lock = struct {
        inner: std.atomic.Mutex = .unlocked,

        fn lock(self: *Lock) void {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        }

        fn unlock(self: *Lock) void {
            self.inner.unlock();
        }
    };

    const OffsetRecord = struct {
        base: u64,
        sizes: [entries_per_record]u16,
    };

    const Entry = struct {
        name_offset: u32,
        is_file: bool,
        file_offset: u64,
        file_size: u64,
        dir_start: u32,
        dir_count: u32,
    };

    /// Opens an archive at `path` inside `dir`. Caller owns the reader.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) !*Reader {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const total = try file.length(io);
        if (total < footer_size) return error.NotArchive;

        var footer: [footer_size]u8 = undefined;
        const got = try file.readPositionalAll(io, &footer, total - footer_size);
        if (got != footer.len) return error.NotArchive;
        const sections = parseFooter(&footer) orelse return error.NotArchive;
        if (sections.total != total) return error.NotArchive;
        for (sections.ranges) |range| {
            if (range.offset > total or range.size > total - range.offset) return error.NotArchive;
        }
        // Sections we read must not alias each other; a hostile footer
        // could otherwise make the tree describe the compressed data.
        const live = [_]Section{
            sections.compressed,
            sections.offset_records,
            sections.names,
            sections.tree,
        };
        for (live, 0..) |a, i| {
            for (live[0..i]) |b| {
                const a_end = a.offset + a.size;
                const b_end = b.offset + b.size;
                if (a.offset < b_end and b.offset < a_end) return error.NotArchive;
            }
        }
        if (sections.offset_records.size % record_size != 0 or
            sections.offset_records.size > std.math.maxInt(u32)) return error.NotArchive;
        if (sections.names.size > 0x7fffffff) return error.NotArchive;
        if (sections.tree.size == 0 or sections.tree.size % entry_size != 0) return error.NotArchive;

        const self = try allocator.create(Reader);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .offset_records = &.{},
            .name_table = &.{},
            .entries = &.{},
            .compressed_offset = sections.compressed.offset,
            .compressed_size = sections.compressed.size,
            .cache_data = &.{},
            .cache_index = .{invalid_block} ** cache_blocks,
            .cache_tick = .{0} ** cache_blocks,
            .comp_scratch = &.{},
        };

        const record_count = sections.offset_records.size / record_size;
        if (record_count == 0) return error.NotArchive;
        var raw_records = try allocator.alloc(u8, sections.offset_records.size);
        defer allocator.free(raw_records);
        try readExact(self, sections.offset_records.offset, raw_records);
        self.offset_records = try allocator.alloc(OffsetRecord, record_count);
        errdefer allocator.free(self.offset_records);
        for (self.offset_records, 0..) |*record, i| {
            const bytes = raw_records[i * record_size ..][0..record_size];
            record.base = std.mem.readInt(u64, bytes[0..8], .big);
            for (&record.sizes, 0..) |*size, j| {
                size.* = std.mem.readInt(u16, bytes[8 + j * 2 ..][0..2], .big);
            }
        }

        self.name_table = try allocator.alloc(u8, sections.names.size);
        errdefer allocator.free(self.name_table);
        if (self.name_table.len != 0) try readExact(self, sections.names.offset, self.name_table);

        const entry_count = sections.tree.size / entry_size;
        var raw_entries = try allocator.alloc(u8, sections.tree.size);
        defer allocator.free(raw_entries);
        try readExact(self, sections.tree.offset, raw_entries);
        self.entries = try allocator.alloc(Entry, entry_count);
        errdefer allocator.free(self.entries);
        for (self.entries, 0..) |*entry, i| {
            const bytes = raw_entries[i * entry_size ..][0..entry_size];
            const flag = std.mem.readInt(u32, bytes[0..4], .big);
            const a = std.mem.readInt(u32, bytes[4..8], .big);
            const b = std.mem.readInt(u32, bytes[8..12], .big);
            const c = std.mem.readInt(u32, bytes[12..16], .big);
            entry.name_offset = flag & 0x7fffffff;
            entry.is_file = flag & 0x80000000 != 0;
            entry.file_offset = a | (@as(u64, c & 0xffff) << 32);
            entry.file_size = b | (@as(u64, c >> 16) << 32);
            entry.dir_start = a;
            entry.dir_count = b;
        }
        if (self.entries[0].is_file) return error.NotArchive;
        if (self.nameAt(self.entries[0].name_offset).len != 0) return error.NotArchive;
        try self.validateTree();

        self.cache_data = try allocator.alloc(u8, cache_blocks * block_size);
        errdefer allocator.free(self.cache_data);
        self.comp_scratch = try allocator.alloc(u8, block_size);
        errdefer allocator.free(self.comp_scratch);
        return self;
    }

    pub fn close(self: *Reader) void {
        self.file.close(self.io);
        self.allocator.free(self.offset_records);
        self.allocator.free(self.name_table);
        self.allocator.free(self.entries);
        self.allocator.free(self.cache_data);
        self.allocator.free(self.comp_scratch);
        self.allocator.destroy(self);
    }

    /// Rejects out-of-range directory spans and file extents, so later
    /// indexing and offset arithmetic cannot be driven out of bounds.
    fn validateTree(self: *Reader) !void {
        const stream = std.math.mul(u64, self.offset_records.len, entries_per_record * block_size) catch
            return error.NotArchive;
        for (self.entries) |*entry| {
            if (!entry.is_file) {
                const end = std.math.add(u64, entry.dir_start, entry.dir_count) catch
                    return error.NotArchive;
                if (end > self.entries.len) return error.NotArchive;
                continue;
            }
            const end = std.math.add(u64, entry.file_offset, entry.file_size) catch
                return error.NotArchive;
            if (end > stream) return error.NotArchive;
        }
    }

    /// Resolves a `/`- or `\`-separated path, case-insensitively. Empty
    /// names the archive root, as does `"."` from mount normalization.
    pub fn lookup(self: *Reader, path: []const u8) ?u32 {
        if (path.len == 0 or std.mem.eql(u8, path, ".")) return 0;
        var current: u32 = 0;
        var rest = path;
        while (true) {
            while (rest.len != 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
            if (rest.len == 0) return current;
            var end: usize = 0;
            while (end < rest.len and rest[end] != '/' and rest[end] != '\\') end += 1;
            const want = rest[0..end];
            rest = rest[end..];
            const entry = &self.entries[current];
            if (entry.is_file) return null;
            var found: ?u32 = null;
            var i: u32 = 0;
            while (i < entry.dir_count) : (i += 1) {
                const child = entry.dir_start + i;
                if (child >= self.entries.len) return null;
                if (namesEqual(want, self.nameAt(self.entries[child].name_offset))) {
                    found = child;
                    break;
                }
            }
            current = found orelse return null;
        }
    }

    pub fn isFile(self: *Reader, node: u32) bool {
        return self.entries[node].is_file;
    }

    pub fn isDirectory(self: *Reader, node: u32) bool {
        return !self.entries[node].is_file;
    }

    pub fn fileSize(self: *Reader, node: u32) u64 {
        return self.entries[node].file_size;
    }

    pub fn dirChildCount(self: *Reader, node: u32) u32 {
        if (self.entries[node].is_file) return 0;
        return self.entries[node].dir_count;
    }

    pub fn dirChild(self: *Reader, node: u32, index: u32) struct { name: []const u8, is_file: bool, size: u64 } {
        const child = &self.entries[self.entries[node].dir_start + index];
        return .{
            .name = self.nameAt(child.name_offset),
            .is_file = child.is_file,
            .size = if (child.is_file) child.file_size else 0,
        };
    }

    /// Node index of a directory's `index`-th child, for recursive walks.
    pub fn dirChildNode(self: *Reader, node: u32, index: u32) u32 {
        return self.entries[node].dir_start + index;
    }

    /// Reads up to `buffer.len` bytes from `offset`, like pread. Returns
    /// bytes read; short at end of file.
    pub fn readAt(self: *Reader, node: u32, offset: u64, buffer: []u8) !usize {
        if (node >= self.entries.len) return error.CorruptArchive;
        const entry = &self.entries[node];
        if (!entry.is_file) return error.IsDirectory;
        if (offset >= entry.file_size) return 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        var remaining: usize = @intCast(@min(@as(u64, buffer.len), entry.file_size - offset));
        var pos = offset;
        var done: usize = 0;
        while (remaining != 0) {
            const raw: u64 = std.math.add(u64, entry.file_offset, pos) catch return error.CorruptArchive;
            const block_index = raw / block_size;
            const at: usize = @intCast(raw % block_size);
            const step: usize = @min(remaining, block_size - at);
            const data = try self.blockLocked(block_index);
            @memcpy(buffer[done..][0..step], data[at..][0..step]);
            pos += step;
            done += step;
            remaining -= step;
        }
        return done;
    }

    pub fn readAlloc(self: *Reader, node: u32, allocator: std.mem.Allocator, maximum: usize) ![]u8 {
        const size = self.fileSize(node);
        if (size > maximum) return error.FileTooBig;
        const out = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(out);
        var done: usize = 0;
        while (done < out.len) {
            const step = try self.readAt(node, done, out[done..]);
            if (step == 0) return error.CorruptArchive;
            done += step;
        }
        return out;
    }

    fn nameAt(self: *Reader, offset: u32) []const u8 {
        if (offset == 0x7fffffff or offset >= self.name_table.len) return "";
        var len: usize = self.name_table[offset] & 0x7f;
        var start: usize = offset + 1;
        if (self.name_table[offset] & 0x80 != 0) {
            if (offset + 1 >= self.name_table.len) return "";
            len |= @as(usize, self.name_table[offset + 1]) << 7;
            start = offset + 2;
        }
        if (start + len > self.name_table.len) return "";
        return self.name_table[start..][0..len];
    }

    fn blockLocked(self: *Reader, index: u64) ![]const u8 {
        for (&self.cache_index, 0..) |*slot, i| {
            if (slot.* == index) {
                self.clock += 1;
                self.cache_tick[i] = self.clock;
                return self.cache_data[i * block_size ..][0..block_size];
            }
        }
        self.clock += 1;
        var victim: usize = 0;
        for (&self.cache_tick, 0..) |*tick, i| {
            if (tick.* < self.cache_tick[victim]) victim = i;
        }
        try self.loadBlock(index, self.cache_data[victim * block_size ..][0..block_size]);
        self.cache_index[victim] = index;
        self.cache_tick[victim] = self.clock;
        return self.cache_data[victim * block_size ..][0..block_size];
    }

    fn loadBlock(self: *Reader, index: u64, out: []u8) !void {
        const record_index: usize = @intCast(index / entries_per_record);
        const sub: usize = @intCast(index % entries_per_record);
        if (record_index >= self.offset_records.len) return error.CorruptArchive;
        const record = &self.offset_records[record_index];
        var offset = record.base;
        for (record.sizes[0..sub]) |size| {
            offset = std.math.add(u64, offset, @as(u64, size) + 1) catch return error.CorruptArchive;
        }
        const size: u64 = @as(u64, record.sizes[sub]) + 1;
        if (offset > self.compressed_size or size > self.compressed_size - offset) return error.CorruptArchive;
        const absolute = std.math.add(u64, self.compressed_offset, offset) catch return error.CorruptArchive;
        if (size == block_size) {
            try readExact(self, absolute, out);
            return;
        }
        try readExact(self, absolute, self.comp_scratch[0..@intCast(size)]);
        var in: std.Io.Reader = .fixed(self.comp_scratch[0..@intCast(size)]);
        var decoder = std.compress.zstd.Decompress.init(&in, &.{}, .{});
        var writer = std.Io.Writer.fixed(out);
        const written = decoder.reader.streamRemaining(&writer) catch return error.CorruptArchive;
        if (decoder.err != null or written != block_size) return error.CorruptArchive;
    }

    fn readExact(self: *Reader, offset: u64, buffer: []u8) !void {
        // shortcut: no size cap on metadata reads; sections are range-checked
        // against the file size at open, so a hostile footer cannot OOM here.
        const got = try self.file.readPositionalAll(self.io, buffer, offset);
        if (got != buffer.len) return error.CorruptArchive;
    }
};

fn namesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (fold(x) != fold(y)) return false;
    }
    return true;
}

fn fold(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

const Section = struct { offset: u64, size: u64 };

const Sections = struct {
    compressed: Section,
    offset_records: Section,
    names: Section,
    tree: Section,
    ranges: [6]Section,
    total: u64,
};

fn parseFooter(footer: *const [footer_size]u8) ?Sections {
    var sections: Sections = undefined;
    var at: usize = 0;
    for (&sections.ranges) |*range| {
        range.offset = std.mem.readInt(u64, footer[at..][0..8], .big);
        range.size = std.mem.readInt(u64, footer[at + 8 ..][0..8], .big);
        at += 16;
    }
    at += 32; // integrity hash, unchecked
    sections.total = std.mem.readInt(u64, footer[at..][0..8], .big);
    at += 8;
    if (std.mem.readInt(u32, footer[at..][0..4], .big) != version) return null;
    if (std.mem.readInt(u32, footer[at + 4 ..][0..4], .big) != magic) return null;
    sections.compressed = sections.ranges[0];
    sections.offset_records = sections.ranges[1];
    sections.names = sections.ranges[2];
    sections.tree = sections.ranges[3];
    return sections;
}

test "archive round trip serves a small file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestArchive(testing.io, tmp.dir, "game.zar", &.{.{
        .path = "eboot.bin",
        .data = "fake-elf-bytes",
    }});

    var reader = try Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    const node = reader.lookup("eboot.bin") orelse return error.FileNotFound;
    try testing.expect(reader.isFile(node));
    try testing.expectEqual(@as(u64, "fake-elf-bytes".len), reader.fileSize(node));
    var out: [32]u8 = undefined;
    const count = try reader.readAt(node, 0, &out);
    try testing.expectEqualStrings("fake-elf-bytes", out[0..count]);
}

test "archive lookup is case-insensitive and slash-agnostic" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestArchive(testing.io, tmp.dir, "game.zar", &.{.{
        .path = "sce_sys/param.json",
        .data = "{}",
    }});

    var reader = try Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    try testing.expect(reader.lookup("SCE_SYS\\PARAM.JSON") != null);
    try testing.expect(reader.lookup("sce_sys/nope.json") == null);
}

test "archive lists directory children" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestArchive(testing.io, tmp.dir, "game.zar", &.{
        .{ .path = "eboot.bin", .data = "elf" },
        .{ .path = "sce_sys/param.json", .data = "{}" },
    });

    var reader = try Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    const root = reader.lookup("") orelse return error.FileNotFound;
    try testing.expect(reader.isDirectory(root));
    try testing.expectEqual(@as(u32, 2), reader.dirChildCount(root));
}

test "archive rejects a bad magic" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.zar", .data = "not a zarchive" });
    try testing.expectError(error.NotArchive, Reader.open(testing.io, tmp.dir, "bad.zar", testing.allocator));
}

test "archive rejects overlapping sections" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestArchive(testing.io, tmp.dir, "game.zar", &.{.{ .path = "eboot.bin", .data = "elf" }});
    // Point the name section at the file tree's offset.
    var file = try tmp.dir.openFile(testing.io, "game.zar", .{ .mode = .read_write });
    defer file.close(testing.io);
    const total = try file.length(testing.io);
    var footer: [footer_size]u8 = undefined;
    _ = try file.readPositionalAll(testing.io, &footer, total - footer_size);
    @memcpy(footer[32..40], footer[48..56]);
    try file.writePositionalAll(testing.io, &footer, total - footer_size);
    try testing.expectError(error.NotArchive, Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator));
}

test "archive rejects file extents past the block stream" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestArchive(testing.io, tmp.dir, "game.zar", &.{.{ .path = "eboot.bin", .data = "elf" }});
    var file = try tmp.dir.openFile(testing.io, "game.zar", .{ .mode = .read_write });
    defer file.close(testing.io);
    const total = try file.length(testing.io);
    var footer: [footer_size]u8 = undefined;
    _ = try file.readPositionalAll(testing.io, &footer, total - footer_size);
    const tree_offset = std.mem.readInt(u64, footer[48..56], .big);
    // First file entry lives at tree offset +16; inflate its size high word.
    var entry: [16]u8 = undefined;
    _ = try file.readPositionalAll(testing.io, &entry, tree_offset + 16);
    @memset(entry[12..16], 0xff);
    try file.writePositionalAll(testing.io, &entry, tree_offset + 16);
    try testing.expectError(error.NotArchive, Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator));
}

test "archive reads a zstd-compressed block" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 23-byte zstd frame expanding to 64KiB of 'A'.
    const hex = "28b52ffd6400ff4d000008410100fc7f742704cf99e954";
    const frame = try testing.allocator.alloc(u8, hex.len / 2);
    defer testing.allocator.free(frame);
    _ = try std.fmt.hexToBytes(frame, hex);
    try writeTestArchiveRaw(testing.io, tmp.dir, "game.zar", &.{
        .{ .path = "big.bin", .data = frame, .compressed = true },
    }, 65536);

    var reader = try Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    const node = reader.lookup("big.bin") orelse return error.FileNotFound;
    try testing.expectEqual(@as(u64, 65536), reader.fileSize(node));
    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), try reader.readAt(node, 65500, &out));
    try testing.expectEqualStrings("AAAAAAAA", &out);
}

// --- Synthetic archives for tests. Single block per file. ---

pub const TestFile = struct {
    path: []const u8,
    data: []const u8,
    compressed: bool = false,
};

pub fn writeTestArchive(io: std.Io, dir: std.Io.Dir, name: []const u8, files: []const TestFile) !void {
    try writeTestArchiveRaw(io, dir, name, files, 0);
}

pub fn writeTestArchiveRaw(io: std.Io, dir: std.Io.Dir, name: []const u8, files: []const TestFile, file_size: u64) !void {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var block_lengths: [8]usize = undefined;
    if (files.len > block_lengths.len) return error.TooManyFiles;
    for (files, 0..) |file, i| {
        if (file.compressed) {
            block_lengths[i] = file.data.len;
            try out.writer.writeAll(file.data);
        } else {
            if (file.data.len > block_size) return error.FileTooBig;
            block_lengths[i] = block_size;
            try out.writer.writeAll(file.data);
            var pad = block_size - file.data.len;
            const zeros = [_]u8{0} ** 1024;
            while (pad != 0) {
                const step: usize = @min(pad, 1024);
                try out.writer.writeAll(zeros[0..step]);
                pad -= step;
            }
        }
    }
    while (out.written().len % 8 != 0) try out.writer.writeByte(0);

    const record_count = (files.len + entries_per_record - 1) / entries_per_record;
    const records_offset = out.written().len;
    var block_cursor: u64 = 0;
    for (0..record_count) |r| {
        try writeU64(&out.writer, block_cursor);
        for (0..entries_per_record) |j| {
            const index = r * entries_per_record + j;
            const len: u64 = if (index < files.len) block_lengths[index] else 1;
            if (index < files.len) block_cursor += len;
            try writeU16(&out.writer, @intCast(len - 1));
        }
    }

    // Name table: unique path components in first-seen order.
    var names: [16][]const u8 = undefined;
    var name_count: usize = 0;
    for (files) |file| {
        var rest = file.path;
        while (rest.len != 0) {
            var end: usize = 0;
            while (end < rest.len and rest[end] != '/') end += 1;
            const part = rest[0..end];
            rest = if (end < rest.len) rest[end + 1 ..] else "";
            var seen = false;
            for (names[0..name_count]) |known| {
                if (std.mem.eql(u8, known, part)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                if (name_count >= names.len) return error.TooManyNames;
                names[name_count] = part;
                name_count += 1;
            }
        }
    }
    const names_offset = out.written().len;
    var name_offsets: [16]u32 = undefined;
    var cursor: u32 = 0;
    for (names[0..name_count], 0..) |part, i| {
        name_offsets[i] = cursor;
        if (part.len >= 0x80) return error.NameTooLong;
        try out.writer.writeByte(@intCast(part.len));
        cursor += 1;
        try out.writer.writeAll(part);
        cursor += @intCast(part.len);
    }

    // File tree in BFS order: root, then each directory's children contiguous.
    const tree_offset = out.written().len;
    const Node = struct { name: u32, is_file: bool, size: u64, offset: u64, children: [8]u32, child_count: u8 };
    var nodes: [24]Node = undefined;
    var node_count: usize = 1;
    nodes[0] = .{ .name = 0x7fffffff, .is_file = false, .size = 0, .offset = 0, .children = undefined, .child_count = 0 };
    var file_block_base: u64 = 0;
    for (files) |file| {
        var parent: usize = 0;
        var rest = file.path;
        while (true) {
            var end: usize = 0;
            while (end < rest.len and rest[end] != '/') end += 1;
            const part = rest[0..end];
            const last = end == rest.len;
            rest = if (last) "" else rest[end + 1 ..];
            var name_index: u32 = 0;
            for (names[0..name_count], 0..) |known, i| {
                if (std.mem.eql(u8, known, part)) {
                    name_index = @intCast(i);
                    break;
                }
            }
            var child: ?usize = null;
            for (nodes[parent].children[0..nodes[parent].child_count]) |c| {
                if (nodes[c].name == name_offsets[name_index]) {
                    child = c;
                    break;
                }
            }
            if (child == null) {
                if (node_count >= nodes.len) return error.TooManyNodes;
                child = node_count;
                node_count += 1;
                const size: u64 = if (last) (if (file.compressed) file_size else file.data.len) else 0;
                nodes[child.?] = .{
                    .name = name_offsets[name_index],
                    .is_file = last,
                    .size = size,
                    .offset = if (last) file_block_base else 0,
                    .children = undefined,
                    .child_count = 0,
                };
                nodes[parent].children[nodes[parent].child_count] = @intCast(child.?);
                nodes[parent].child_count += 1;
            }
            if (last) break;
            parent = child.?;
        }
        file_block_base += 1;
    }

    // Pre-order layout keeps each directory's children contiguous: a
    // node's direct children follow it before any grandchildren.
    var layout: [24]usize = undefined;
    var li: usize = 0;
    var stack: [24]usize = .{0} ++ .{0} ** 23;
    var top: usize = 1;
    while (top != 0) {
        top -= 1;
        const n = stack[top];
        layout[li] = n;
        li += 1;
        var c = nodes[n].child_count;
        while (c != 0) {
            c -= 1;
            stack[top] = nodes[n].children[c];
            top += 1;
        }
    }
    var at_layout: [24]u32 = undefined;
    for (layout[0..li], 0..) |n, i| at_layout[n] = @intCast(i);

    for (layout[0..li]) |n| {
        const node = &nodes[n];
        var flag = node.name;
        if (node.is_file) flag |= 0x80000000;
        try writeU32(&out.writer, flag);
        if (node.is_file) {
            // Each test file occupies exactly one block in file order.
            const abs_off: u64 = node.offset * block_size;
            try writeU32(&out.writer, @truncate(abs_off));
            try writeU32(&out.writer, @truncate(node.size));
            const hi: u32 = (@as(u32, @truncate(node.size >> 32)) << 16) | @as(u32, @truncate(abs_off >> 32));
            try writeU32(&out.writer, hi);
        } else {
            try writeU32(&out.writer, if (node.child_count == 0) 0 else at_layout[n] + 1);
            try writeU32(&out.writer, node.child_count);
            try writeU32(&out.writer, 0);
        }
    }

    const meta_offset = out.written().len;
    const total = out.written().len + footer_size;
    for (sections6(records_offset, names_offset, names_offset, tree_offset, meta_offset)) |section| {
        try writeU64(&out.writer, section[0]);
        try writeU64(&out.writer, section[1]);
    }
    try out.writer.writeAll(&[_]u8{0} ** 32);
    try writeU64(&out.writer, total);
    try writeU32(&out.writer, version);
    try writeU32(&out.writer, magic);

    const bytes = out.written();
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn sections6(records_offset: usize, after_records: usize, names_offset: usize, tree_offset: usize, meta_offset: usize) [6][2]u64 {
    const names_size = tree_offset - names_offset;
    const tree_size = meta_offset - tree_offset;
    return .{
        .{ 0, records_offset },
        .{ records_offset, after_records - records_offset },
        .{ names_offset, names_size },
        .{ tree_offset, tree_size },
        .{ meta_offset, 0 },
        .{ meta_offset, 0 },
    };
}

fn writeU64(w: *std.Io.Writer, v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .big);
    try w.writeAll(&bytes);
}

fn writeU32(w: *std.Io.Writer, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .big);
    try w.writeAll(&bytes);
}

fn writeU16(w: *std.Io.Writer, v: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, v, .big);
    try w.writeAll(&bytes);
}
