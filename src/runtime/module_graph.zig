// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Discovery and two-phase loading of a title's dependent PRX graph.

const std = @import("std");
const memory = @import("memory");
const loader = @import("loader");
const diag = @import("diag");
const hle = @import("hle");

pub const Options = struct {
    /// The executable is relocatable in practice even though titles commonly
    /// describe it as the fixed process image. Address zero is not available to
    /// a normal host process, so the default uses the guest-managed window.
    executable_load_bias: u64 = memory.system_managed.start,
    /// Shared PRX images are packed into the guest system-software window.
    module_load_start: u64 = memory.system_reserved.start,
    maximum_file_size: usize = 512 * 1024 * 1024,
    /// Additional title PRX files to map before guest execution. This models
    /// modules a title later names through `sceKernelLoadStartModule` while the
    /// current runtime still performs graph construction as one safe phase.
    /// Entries may be paths relative to the executable or just basenames.
    preload_modules: []const []const u8 = &.{},
    /// Modules that must be mapped and relocated up front, but whose entry
    /// points are invoked only when the guest calls sceKernelLoadStartModule.
    /// Unity native plug-ins receive their startup argument through that call
    /// and are not valid during the process' dependency initialization phase.
    deferred_modules: []const []const u8 = &.{},
    diagnostics: ?Diagnostics = null,
};

pub const Diagnostics = struct {
    context: ?*anyopaque = null,
    unresolved_fn: *const fn (?*anyopaque, UnresolvedImport) void,

    fn unresolved(self: Diagnostics, diagnostic: UnresolvedImport) void {
        self.unresolved_fn(self.context, diagnostic);
    }
};

pub const UnresolvedImport = struct {
    path: []const u8,
    import: loader.Import,
};

pub const Module = struct {
    /// Path relative to the directory containing the executable.
    path: []u8,
    bytes: []u8,
    image: loader.Image,
    dynamic_info: loader.DynamicInfo,
    dependencies: std.ArrayList(usize) = .empty,
    deferred_start: bool = false,
    prepared: ?loader.PreparedImage = null,
    mapped: ?loader.MappedImage = null,

    fn deinitResources(self: *Module, gpa: std.mem.Allocator) void {
        self.dependencies.deinit(gpa);
        self.dynamic_info.deinit(gpa);
        gpa.free(self.bytes);
        gpa.free(self.path);
    }
};

/// Reads already-mapped guest bytes. The address space is identity mapped, so
/// this is a host load; it is only ever called on addresses taken from a
/// module's own program headers, which are mapped by construction.
fn readMappedBytes(address: u64, out: []u8) bool {
    if (address == 0) return false;
    const bytes: [*]const u8 = @ptrFromInt(address);
    @memcpy(out, bytes[0..out.len]);
    return true;
}

const Candidate = struct {
    path: []u8,

    fn deinit(self: *Candidate, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }
};

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Module) = .empty,
    root_index: usize = 0,
    initialization_order: std.ArrayList(usize) = .empty,
    module_images: std.ArrayList(*loader.MappedImage) = .empty,

    /// Unloads the executable first, then PRX modules in reverse initializer
    /// order. Parsed file buffers are released only after all registry entries
    /// that copied from them have been removed.
    pub fn deinit(self: *ModuleGraph) void {
        if (self.root_index < self.nodes.items.len) self.deinitMapped(self.root_index);
        var order_index = self.initialization_order.items.len;
        while (order_index > 0) {
            order_index -= 1;
            self.deinitMapped(self.initialization_order.items[order_index]);
        }
        for (self.nodes.items, 0..) |_, index| self.deinitMapped(index);

        self.module_images.deinit(self.allocator);
        self.initialization_order.deinit(self.allocator);
        for (self.nodes.items) |*node| node.deinitResources(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    fn deinitMapped(self: *ModuleGraph, index: usize) void {
        const node = &self.nodes.items[index];
        if (node.mapped) |*mapped| {
            mapped.deinit();
            node.mapped = null;
        }
        if (node.prepared) |*prepared| {
            prepared.deinit();
            node.prepared = null;
        }
    }

    pub fn executable(self: *ModuleGraph) *loader.MappedImage {
        return &self.nodes.items[self.root_index].mapped.?;
    }

    /// Dependency-first list suitable for runtime ProcessOptions.modules.
    pub fn modules(self: *ModuleGraph) []const *loader.MappedImage {
        return self.module_images.items;
    }

    pub fn moduleCount(self: *const ModuleGraph) usize {
        return self.nodes.items.len - 1;
    }

    /// Publishes each mapped module's extent and unwind tables to the firmware.
    ///
    /// A throwing title asks the kernel, for every return address on its stack,
    /// which module owns it and where that module's unwind index lives. Without
    /// this the C++ runtime finds no handler and every exception terminates the
    /// process, so this has to be in place before guest code runs.
    ///
    /// The returned list backs the published registry and must outlive the
    /// process; the caller owns it.
    pub fn publishUnwindModules(
        self: *ModuleGraph,
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error![]hle.unwind.Module {
        var list: std.ArrayList(hle.unwind.Module) = .empty;
        errdefer list.deinit(gpa);

        for (self.nodes.items) |*node| {
            const mapped = if (node.mapped) |*m| m else continue;

            var start: u64 = std.math.maxInt(u64);
            var end: u64 = 0;
            for (mapped.ranges.items) |range| {
                start = @min(start, range.start);
                end = @max(end, range.end);
            }
            if (end == 0) continue;

            var entry = hle.unwind.Module{
                .name = std.fs.path.basename(node.path),
                .start = start,
                .end = end,
            };

            if (node.image.findSegment(.gnu_eh_frame)) |header| {
                entry.eh_frame_header = mapped.load_bias + header.vaddr;
                entry.eh_frame_header_size = header.memsz;
                if (hle.unwind.decodeEhFrame(
                    entry.eh_frame_header,
                    entry.eh_frame_header_size,
                    &readMappedBytes,
                )) |address| {
                    entry.eh_frame = address;
                    // The index sits immediately after the records in every
                    // layout seen so far; when it does not, leaving the size
                    // unset is safer than inventing an extent.
                    if (address < entry.eh_frame_header) {
                        entry.eh_frame_size = entry.eh_frame_header - address;
                    }
                }
            }

            try list.append(gpa, entry);
        }

        const published = try list.toOwnedSlice(gpa);
        hle.unwind.attach(published);
        return published;
    }

    /// Publishes the loaded modules so a title can ask for them by path.
    ///
    /// Titles load some of their own modules explicitly instead of through the
    /// dynamic tables. Everything adjacent to the executable is already mapped
    /// and relocated by then, so the request resolves to what exists rather
    /// than loading a second copy with its own relocations and duplicate state.
    ///
    /// The returned list backs the published registry and must outlive the
    /// process; the caller owns it.
    pub fn publishModules(
        self: *ModuleGraph,
        gpa: std.mem.Allocator,
        guest_exports: *loader.GuestExportRegistry,
    ) std.mem.Allocator.Error![]hle.modules.Module {
        var list: std.ArrayList(hle.modules.Module) = .empty;
        errdefer list.deinit(gpa);

        var next_handle: i32 = hle.modules.executable_handle + 1;
        for (self.nodes.items, 0..) |*node, index| {
            const mapped = if (node.mapped) |*m| m else continue;

            var start: u64 = std.math.maxInt(u64);
            var end: u64 = 0;
            for (mapped.ranges.items) |range| {
                start = @min(start, range.start);
                end = @max(end, range.end);
            }
            if (end == 0) continue;

            // The executable keeps the handle titles treat as the process
            // image; libraries are numbered after it.
            const handle = if (index == self.root_index)
                hle.modules.executable_handle
            else handle: {
                const value = next_handle;
                next_handle += 1;
                break :handle value;
            };

            try list.append(gpa, .{
                .handle = handle,
                .path = node.path,
                .load_bias = mapped.load_bias,
                .start = start,
                .end = end,
                .export_module_id = if (mapped.guest_export_module) |module| module.id else 0,
                .init_functions = mapped.init_functions.items,
                .deferred_start = node.deferred_start,
            });
        }

        const published = try list.toOwnedSlice(gpa);
        hle.modules.attach(published);
        hle.modules.attachExportResolver(@ptrCast(guest_exports), &resolvePublishedExport);
        return published;
    }

    /// Builds an address-to-symbol map covering every mapped module.
    ///
    /// Exports are re-collected rather than read back from the shared registry:
    /// the registry is keyed for resolution, not for reverse lookup, and it
    /// deliberately loses which image an entry came from once several modules
    /// export the same identifier.
    ///
    /// The returned map borrows module paths and export names from this graph,
    /// so it must not outlive it.
    pub fn buildSymbolMap(
        self: *ModuleGraph,
        gpa: std.mem.Allocator,
    ) !diag.SymbolMap {
        var map = diag.SymbolMap{};
        errdefer map.deinit(gpa);

        var module_exports: std.ArrayList(loader.GuestExport) = .empty;
        defer module_exports.deinit(gpa);

        for (self.nodes.items) |*node| {
            const mapped = if (node.mapped) |*m| m else continue;

            module_exports.clearRetainingCapacity();
            // A module that exports nothing is still worth registering: module
            // and offset alone already locate code in a dump of the file.
            loader.collectGuestExports(
                gpa,
                &module_exports,
                node.image,
                &node.dynamic_info,
                mapped.load_bias,
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => module_exports.clearRetainingCapacity(),
            };

            try map.addModule(
                gpa,
                std.fs.path.basename(node.path),
                mapped.load_bias,
                mapped.ranges.items,
                module_exports.items,
            );
        }

        return map;
    }
};

/// Loads an executable and every adjacent PRX/SRPX that is reachable through
/// DT_NEEDED or the PS5 needed-module declarations. Missing files represent
/// firmware/HLE dependencies and do not create graph nodes.
pub fn loadFromDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    executable_name: []const u8,
    address_space: *memory.AddressSpace,
    tls_registry: *loader.TlsRegistry,
    guest_exports: *loader.GuestExportRegistry,
    resolver: ?loader.Resolver,
    options: Options,
) !ModuleGraph {
    var graph = ModuleGraph{ .allocator = gpa };
    errdefer graph.deinit();

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(gpa);
        candidates.deinit(gpa);
    }
    try collectCandidates(gpa, io, directory, executable_name, &candidates);

    const root_bytes = try directory.readFileAlloc(
        io,
        executable_name,
        gpa,
        .limited(options.maximum_file_size),
    );
    try appendNode(&graph, executable_name, root_bytes);

    // Explicitly requested modules are roots of their own dynamic subgraphs.
    // Making them dependencies of the executable maps, relocates and
    // initializes them in the existing dependency-first phase, after which a
    // guest LoadStartModule request can return their published handle.
    for (options.preload_modules) |requested| {
        const candidate_index = findCandidate(candidates.items, requested, true) orelse
            return error.FileNotFound;
        const dependency = try ensureNode(
            &graph,
            io,
            directory,
            candidates.items[candidate_index].path,
            options.maximum_file_size,
        );
        try appendDependency(&graph, graph.root_index, dependency);
    }

    // Native plug-ins are still part of the mapped graph so their relocations,
    // exports and unwind information are ready before concurrent guest code
    // begins. Their constructors are deliberately held back: LoadStartModule
    // supplies an argument block that Unity plug-ins commonly require.
    for (options.deferred_modules) |requested| {
        const candidate_index = findCandidate(candidates.items, requested, true) orelse
            return error.FileNotFound;
        const dependency = try ensureNode(
            &graph,
            io,
            directory,
            candidates.items[candidate_index].path,
            options.maximum_file_size,
        );
        graph.nodes.items[dependency].deferred_start = true;
        try appendDependency(&graph, graph.root_index, dependency);
    }

    // Iterating a growing list is the graph-discovery queue. Each path is
    // parsed at most once, while duplicate dependency declarations become one
    // edge to the existing node.
    var node_index: usize = 0;
    while (node_index < graph.nodes.items.len) : (node_index += 1) {
        const needed_files = graph.nodes.items[node_index].dynamic_info.needed_files.items;
        for (needed_files) |needed| {
            if (findCandidate(candidates.items, needed, true)) |candidate_index| {
                const dependency = try ensureNode(
                    &graph,
                    io,
                    directory,
                    candidates.items[candidate_index].path,
                    options.maximum_file_size,
                );
                try appendDependency(&graph, node_index, dependency);
            }
        }

        const needed_modules = graph.nodes.items[node_index].dynamic_info.needed_modules.items;
        for (needed_modules) |needed| {
            if (findCandidate(candidates.items, needed.name, false)) |candidate_index| {
                const dependency = try ensureNode(
                    &graph,
                    io,
                    directory,
                    candidates.items[candidate_index].path,
                    options.maximum_file_size,
                );
                try appendDependency(&graph, node_index, dependency);
            }
        }
    }

    try prepareAll(
        &graph,
        address_space,
        tls_registry,
        guest_exports,
        options,
    );
    try inferGuestDependencies(&graph, guest_exports);
    try buildInitializationOrder(&graph);
    try linkAll(&graph, resolver, options.diagnostics);

    try graph.module_images.ensureTotalCapacity(gpa, graph.initialization_order.items.len);
    for (graph.initialization_order.items) |index| {
        if (graph.nodes.items[index].deferred_start) continue;
        graph.module_images.appendAssumeCapacity(&graph.nodes.items[index].mapped.?);
    }
    return graph;
}

fn resolvePublishedExport(context: *anyopaque, module_id: u64, name: []const u8) ?u64 {
    const registry: *loader.GuestExportRegistry = @ptrCast(@alignCast(context));
    const id = hle.nid.fromName(name);
    return registry.resolveInModule(module_id, &id, .func) orelse
        registry.resolveInModule(module_id, &id, .object) orelse
        registry.resolveInModule(module_id, &id, .no_type);
}

fn collectCandidates(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    executable_name: []const u8,
    out: *std.ArrayList(Candidate),
) !void {
    var walker = try directory.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.ascii.eqlIgnoreCase(entry.path, executable_name)) continue;
        const extension = std.fs.path.extension(entry.basename);
        if (!std.ascii.eqlIgnoreCase(extension, ".prx") and
            !std.ascii.eqlIgnoreCase(extension, ".sprx")) continue;
        try out.append(gpa, .{ .path = try gpa.dupe(u8, entry.path) });
    }
    std.mem.sort(Candidate, out.items, {}, candidateLessThan);
}

fn candidateLessThan(_: void, left: Candidate, right: Candidate) bool {
    return std.ascii.lessThanIgnoreCase(left.path, right.path);
}

fn findCandidate(candidates: []const Candidate, needed: []const u8, exact_file: bool) ?usize {
    for (candidates, 0..) |candidate, index| {
        const basename = std.fs.path.basename(candidate.path);
        const candidate_name = if (exact_file) basename else std.fs.path.stem(basename);
        const needed_name = if (exact_file) std.fs.path.basename(needed) else std.fs.path.stem(needed);
        if (std.ascii.eqlIgnoreCase(candidate_name, needed_name)) return index;
    }
    return null;
}

fn appendNode(graph: *ModuleGraph, path: []const u8, bytes: []u8) !void {
    errdefer graph.allocator.free(bytes);
    const owned_path = try graph.allocator.dupe(u8, path);
    errdefer graph.allocator.free(owned_path);
    const image = try loader.parseImage(bytes);
    var info = try loader.parseDynamic(graph.allocator, image);
    errdefer info.deinit(graph.allocator);
    try graph.nodes.append(graph.allocator, .{
        .path = owned_path,
        .bytes = bytes,
        .image = image,
        .dynamic_info = info,
    });
}

fn ensureNode(
    graph: *ModuleGraph,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    maximum_file_size: usize,
) !usize {
    for (graph.nodes.items, 0..) |node, index| {
        if (std.ascii.eqlIgnoreCase(node.path, path)) return index;
    }
    const bytes = try directory.readFileAlloc(io, path, graph.allocator, .limited(maximum_file_size));
    try appendNode(graph, path, bytes);
    return graph.nodes.items.len - 1;
}

fn appendDependency(graph: *ModuleGraph, owner: usize, dependency: usize) !void {
    if (owner == dependency) return;
    for (graph.nodes.items[owner].dependencies.items) |existing| {
        if (existing == dependency) return;
    }
    try graph.nodes.items[owner].dependencies.append(graph.allocator, dependency);
}

/// Adds the dependencies which PS5 import metadata cannot express as a file
/// edge. Some firmware modules are shipped under a short filename but export
/// a different public module name (notably libc.prx/libSceLibcInternal), so a
/// filename-only graph can otherwise run a consumer's initializer first.
///
/// Every image has already published its guest exports during prepareAll. Use
/// the same exact-then-NID-fallback lookup as relocation, then attribute the
/// resolved address back to its mapped provider.
fn inferGuestDependencies(
    graph: *ModuleGraph,
    guest_exports: *loader.GuestExportRegistry,
) !void {
    for (graph.nodes.items, 0..) |*node, owner_index| {
        var module_imports = try loader.collectImports(
            graph.allocator,
            node.image,
            &node.dynamic_info,
        );
        defer module_imports.deinit(graph.allocator);

        for (module_imports.items.items) |*import| {
            if (import.symbol_type == .tls) continue;
            const address = guest_exports.resolveExact(import) orelse
                guest_exports.resolveById(import) orelse continue;
            const provider_index = findPreparedProvider(graph, address) orelse continue;
            try appendDependency(graph, owner_index, provider_index);
        }
    }
}

fn findPreparedProvider(graph: *const ModuleGraph, address: u64) ?usize {
    for (graph.nodes.items, 0..) |node, index| {
        const prepared = node.prepared orelse continue;
        for (prepared.mapped.ranges.items) |range| {
            if (address >= range.start and address < range.end) return index;
        }
    }
    return null;
}

const Visit = enum { unseen, active, complete };

fn buildInitializationOrder(graph: *ModuleGraph) !void {
    const visits = try graph.allocator.alloc(Visit, graph.nodes.items.len);
    defer graph.allocator.free(visits);
    @memset(visits, .unseen);
    try visitNode(graph, visits, graph.root_index);
}

fn visitNode(graph: *ModuleGraph, visits: []Visit, index: usize) std.mem.Allocator.Error!void {
    switch (visits[index]) {
        .complete => return,
        // All nodes are mapped before relocation, so a dependency cycle is
        // legal. The active edge is simply not repeated in initializer order.
        .active => return,
        .unseen => {},
    }
    visits[index] = .active;
    for (graph.nodes.items[index].dependencies.items) |dependency| {
        try visitNode(graph, visits, dependency);
    }
    visits[index] = .complete;
    if (index != graph.root_index) try graph.initialization_order.append(graph.allocator, index);
}

const ImageSpan = struct {
    start: u64,
    end: u64,
    alignment: u64,
};

fn imageSpan(image: loader.Image) !ImageSpan {
    var found = false;
    var start: u64 = std.math.maxInt(u64);
    var end: u64 = 0;
    var alignment: u64 = memory.page_size;
    for (image.program_headers) |header| {
        if (header.segmentType() != .load or header.memsz == 0) continue;
        found = true;
        start = @min(start, alignDown(header.vaddr, memory.page_size));
        const raw_end = std.math.add(u64, header.vaddr, header.memsz) catch
            return error.AddressOverflow;
        end = @max(end, try alignForward(raw_end, memory.page_size));
        if (header.@"align" != 0) alignment = @max(alignment, header.@"align");
    }
    if (!found) return error.NoLoadSegments;
    if (!std.math.isPowerOfTwo(alignment)) return error.InvalidLoadSegment;
    return .{ .start = start, .end = end, .alignment = alignment };
}

fn prepareAll(
    graph: *ModuleGraph,
    address_space: *memory.AddressSpace,
    tls_registry: *loader.TlsRegistry,
    guest_exports: *loader.GuestExportRegistry,
    options: Options,
) !void {
    var next_module_address = options.module_load_start;
    for (graph.nodes.items, 0..) |*node, index| {
        const load_bias = if (index == graph.root_index)
            options.executable_load_bias
        else bias: {
            const span = try imageSpan(node.image);
            if (next_module_address < span.start) return error.AddressOverflow;
            const unaligned_bias = next_module_address - span.start;
            const module_bias = try alignForward(unaligned_bias, span.alignment);
            const mapped_end = std.math.add(u64, module_bias, span.end) catch
                return error.AddressOverflow;
            next_module_address = try alignForward(
                std.math.add(u64, mapped_end, memory.page_size) catch
                    return error.AddressOverflow,
                memory.page_size,
            );
            break :bias module_bias;
        };
        node.prepared = try loader.prepareImage(
            graph.allocator,
            address_space,
            node.image,
            &node.dynamic_info,
            .{
                .load_bias = load_bias,
                .tls_registry = tls_registry,
                .guest_export_registry = guest_exports,
            },
        );
    }
}

fn linkAll(
    graph: *ModuleGraph,
    resolver: ?loader.Resolver,
    diagnostics: ?Diagnostics,
) !void {
    for (graph.initialization_order.items) |index| {
        try linkNode(graph, index, resolver, diagnostics);
    }
    try linkNode(graph, graph.root_index, resolver, diagnostics);
}

fn linkNode(
    graph: *ModuleGraph,
    index: usize,
    resolver: ?loader.Resolver,
    diagnostics: ?Diagnostics,
) !void {
    const node = &graph.nodes.items[index];
    if (diagnostics) |sink| try reportUnresolved(graph.allocator, node, resolver, sink);
    node.mapped = try loader.linkImage(
        &node.prepared.?,
        node.image,
        &node.dynamic_info,
        resolver,
    );
    node.prepared = null;
}

fn reportUnresolved(
    gpa: std.mem.Allocator,
    node: *const Module,
    resolver: ?loader.Resolver,
    diagnostics: Diagnostics,
) !void {
    var module_imports = try loader.collectImports(gpa, node.image, &node.dynamic_info);
    defer module_imports.deinit(gpa);

    for (module_imports.items.items) |import| {
        if (import.binding == .weak) continue;
        const resolved = if (import.symbol_type == .tls)
            if (resolver) |active| active.resolveTls(&import) != null else false
        else if (resolver) |active| active.resolve(&import) != null else false;
        if (!resolved) diagnostics.unresolved(.{ .path = node.path, .import = import });
    }
}

fn alignDown(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

fn alignForward(value: u64, alignment: u64) !u64 {
    const mask = alignment - 1;
    const with_mask = std.math.add(u64, value, mask) catch return error.AddressOverflow;
    return with_mask & ~mask;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a needed module is discovered recursively and initialized before the executable" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // The two PRX files point at each other. Two-phase mapping makes this a
    // valid graph rather than a recursive-load failure.
    var leaf = try minimalImage(testing.allocator, .sce_dynamic, "dependency");
    defer leaf.deinit(testing.allocator);
    var dependency = try minimalImage(testing.allocator, .sce_dynamic, "leaf");
    defer dependency.deinit(testing.allocator);
    var executable = try minimalImage(testing.allocator, .sce_dynexec, "dependency");
    defer executable.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "eboot.bin", .data = executable.bytes() });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dependency.prx", .data = dependency.bytes() });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "leaf.prx", .data = leaf.bytes() });

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var tls_registry = loader.TlsRegistry{};
    defer tls_registry.deinit(testing.allocator);
    var guest_exports = loader.GuestExportRegistry{};
    defer guest_exports.deinit(testing.allocator);

    var graph = try loadFromDir(
        testing.allocator,
        testing.io,
        tmp.dir,
        "eboot.bin",
        &address_space,
        &tls_registry,
        &guest_exports,
        null,
        .{},
    );
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 2), graph.moduleCount());
    try testing.expectEqual(@as(usize, 2), graph.modules().len);
    try testing.expectEqualStrings("dependency.prx", graph.nodes.items[1].path);
    try testing.expectEqualStrings("leaf.prx", graph.nodes.items[2].path);
    try testing.expect(graph.modules()[0] == &graph.nodes.items[2].mapped.?);
    try testing.expect(graph.modules()[1] == &graph.nodes.items[1].mapped.?);
}

test "a deferred module is linked but omitted from process initialization" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var plugin = try minimalImage(testing.allocator, .sce_dynamic, null);
    defer plugin.deinit(testing.allocator);
    var executable = try minimalImage(testing.allocator, .sce_dynexec, null);
    defer executable.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "eboot.bin", .data = executable.bytes() });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.prx", .data = plugin.bytes() });

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var tls_registry = loader.TlsRegistry{};
    defer tls_registry.deinit(testing.allocator);
    var guest_exports = loader.GuestExportRegistry{};
    defer guest_exports.deinit(testing.allocator);

    var graph = try loadFromDir(
        testing.allocator,
        testing.io,
        tmp.dir,
        "eboot.bin",
        &address_space,
        &tls_registry,
        &guest_exports,
        null,
        .{ .deferred_modules = &.{"plugin.prx"} },
    );
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 1), graph.moduleCount());
    try testing.expectEqual(@as(usize, 0), graph.modules().len);
    try testing.expect(graph.nodes.items[1].deferred_start);
    try testing.expect(graph.nodes.items[1].mapped != null);
}

test "the symbol map covers every mapped module" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dependency = try minimalImage(testing.allocator, .sce_dynamic, null);
    defer dependency.deinit(testing.allocator);
    var executable = try minimalImage(testing.allocator, .sce_dynexec, "dependency");
    defer executable.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "eboot.bin", .data = executable.bytes() });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dependency.prx", .data = dependency.bytes() });

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var tls_registry = loader.TlsRegistry{};
    defer tls_registry.deinit(testing.allocator);
    var guest_exports = loader.GuestExportRegistry{};
    defer guest_exports.deinit(testing.allocator);

    var graph = try loadFromDir(
        testing.allocator,
        testing.io,
        tmp.dir,
        "eboot.bin",
        &address_space,
        &tls_registry,
        &guest_exports,
        null,
        .{},
    );
    defer graph.deinit();

    var map = try graph.buildSymbolMap(testing.allocator);
    defer map.deinit(testing.allocator);

    // Every module's own load bias must attribute back to that module, which is
    // what makes a faulting address readable.
    const executable_bias = graph.executable().load_bias;
    const executable_location = map.locate(executable_bias);
    try testing.expectEqualStrings("eboot.bin", executable_location.module.?);
    try testing.expectEqual(@as(u64, 0), executable_location.module_offset);

    const dependency_bias = graph.nodes.items[1].mapped.?.load_bias;
    try testing.expectEqualStrings("dependency.prx", map.locate(dependency_bias).module.?);

    // Address zero belongs to nobody, which is precisely the signal that a call
    // went through a null pointer.
    try testing.expect(!map.locate(0).isKnown());
}

fn minimalImage(
    gpa: std.mem.Allocator,
    object_type: loader.ObjectType,
    needed_module: ?[]const u8,
) !loader.elf.TestImage {
    const strings = if (needed_module) |name|
        try std.fmt.allocPrint(gpa, "\x00{s}\x00", .{name})
    else
        try gpa.dupe(u8, "\x00");
    defer gpa.free(strings);

    var entries: std.ArrayList(loader.dynamic.Entry) = .empty;
    defer entries.deinit(gpa);
    if (needed_module != null) {
        try entries.append(gpa, .{
            .tag = @intFromEnum(loader.dynamic.Tag.sce_strtab),
            .value = 0,
        });
        try entries.append(gpa, .{
            .tag = @intFromEnum(loader.dynamic.Tag.sce_strsz),
            .value = strings.len,
        });
        try entries.append(gpa, .{
            .tag = @intFromEnum(loader.dynamic.Tag.sce_needed_module),
            .value = (@as(u64, 1) << 48) | (@as(u64, 1) << 40) |
                (@as(u64, 1) << 32) | 1,
        });
    }
    try entries.append(gpa, .{ .tag = 0, .value = 0 });

    const header_count: usize = if (needed_module != null) 3 else 1;
    const payload_offset = loader.elf.TestImage.payloadOffset(header_count);
    const dynamic_bytes = std.mem.sliceAsBytes(entries.items);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, dynamic_bytes);
    const strings_offset = payload.items.len;
    try payload.appendSlice(gpa, strings);

    var headers: [3]loader.ProgramHeader = undefined;
    headers[0] = .{
        .type = @intFromEnum(loader.SegmentType.load),
        .flags = 0x5,
        .offset = payload_offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = payload.items.len,
        .memsz = memory.page_size,
        .@"align" = memory.page_size,
    };
    if (needed_module != null) {
        headers[1] = .{
            .type = @intFromEnum(loader.SegmentType.dynamic),
            .flags = 0x4,
            .offset = payload_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = dynamic_bytes.len,
            .memsz = dynamic_bytes.len,
            .@"align" = 8,
        };
        headers[2] = .{
            .type = @intFromEnum(loader.SegmentType.sce_dynlibdata),
            .flags = 0x4,
            .offset = payload_offset + strings_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = strings.len,
            .memsz = strings.len,
            .@"align" = 1,
        };
    }
    return loader.elf.TestImage.build(
        gpa,
        object_type,
        headers[0..header_count],
        payload.items,
    );
}
