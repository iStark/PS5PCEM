// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runtime composition for the memory, loader, HLE, and CPU modules.
//!
//! The lower layers remain independently useful. `Runtime` is the place where
//! they deliberately meet: it owns the one process-wide guest address space,
//! registers firmware exports, adapts the HLE database to the loader's resolver
//! interface, and returns fully mapped and relocated modules.

const std = @import("std");
const memory = @import("memory");
const loader = @import("loader");
const hle = @import("hle");
const cpu = @import("cpu");
pub const process = @import("process.zig");
pub const module_graph = @import("module_graph.zig");
pub const ModuleGraph = module_graph.ModuleGraph;
pub const ModuleGraphOptions = module_graph.Options;

pub const Error = error{
    AlreadyInitialized,
    NotInitialized,
} || memory.Error || hle.symbols.Error || loader.elf.Error || loader.dynamic.Error ||
    loader.image_loader.Error || hle.libs.kernel_threading.Error ||
    hle.libs.kernel_sync.Error || cpu.Error || process.Error || std.mem.Allocator.Error;

pub const ProcessOptions = struct {
    entry: process.Options = .{},
    exit_handler: u64 = 0,
    /// Shared modules in dependency-first initialization order.
    modules: []const *loader.MappedImage = &.{},
};

pub const Runtime = struct {
    allocator: ?std.mem.Allocator = null,
    address_space: ?memory.AddressSpace = null,
    database: hle.Database = .{},
    tls_registry: loader.TlsRegistry = .{},
    guest_exports: loader.GuestExportRegistry = .{},
    thread_manager: hle.libs.kernel_threading.Manager = .{},
    sync_manager: hle.libs.kernel_sync.Manager = .{},
    cpu_dispatcher: cpu.Dispatcher = .{},
    native_cpu_bridge: cpu.NativeBridge = .{},
    initialized: bool = false,

    /// Initializes a stable, caller-owned Runtime value.
    ///
    /// This is an in-place initializer because libkernel retains a pointer to
    /// `address_space`; returning Runtime by value could invalidate that pointer
    /// when the value is moved.
    pub fn init(self: *Runtime, allocator: std.mem.Allocator) Error!void {
        if (self.initialized or self.address_space != null) return Error.AlreadyInitialized;
        self.allocator = allocator;
        self.address_space = try memory.AddressSpace.initWithDirectMemory(
            allocator,
            hle.libs.kernel_memory.direct_memory_size,
        );
        errdefer {
            if (self.address_space) |*space| space.deinit();
            self.address_space = null;
            self.allocator = null;
        }

        hle.libs.kernel_memory.init(allocator);
        errdefer hle.libs.kernel_memory.deinit();
        if (self.address_space) |*space| hle.libs.kernel_memory.attachAddressSpace(space);
        errdefer hle.libs.kernel_memory.attachAddressSpace(null);

        if (self.address_space) |*space| {
            self.thread_manager.init(allocator, space, &self.tls_registry);
        }
        errdefer self.thread_manager.deinit();
        hle.libs.kernel_threading.attachManager(&self.thread_manager);
        errdefer hle.libs.kernel_threading.attachManager(null);

        self.sync_manager.init(allocator);
        errdefer self.sync_manager.deinit();
        hle.libs.kernel_sync.attachManager(&self.sync_manager);
        errdefer hle.libs.kernel_sync.attachManager(null);

        errdefer {
            self.database.deinit(allocator);
            self.database = .{};
        }
        try hle.registerAll(&self.database, allocator);
        hle.libs.kernel_event_queue.reset();
        hle.libs.system_service.reset();
        hle.libs.user_service.reset();
        hle.libs.pad.reset();
        hle.libs.kernel_runtime.attachIo(null);
        hle.libs.kernel_runtime.attachProcessParam(0);
        self.initialized = true;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.initialized) return;
        const allocator = self.allocator.?;

        self.cpu_dispatcher.deinit();
        self.native_cpu_bridge.deinit();
        hle.libs.kernel_sync.attachManager(null);
        self.sync_manager.deinit();
        hle.libs.kernel_threading.attachManager(null);
        self.thread_manager.deinit();
        hle.libs.kernel_memory.attachAddressSpace(null);
        hle.libs.kernel_memory.deinit();
        hle.libs.kernel_event_queue.reset();
        hle.libs.system_service.reset();
        hle.libs.user_service.reset();
        hle.libs.pad.reset();
        hle.libs.kernel_runtime.attachProcessParam(0);
        hle.libs.kernel_runtime.attachIo(null);
        self.database.deinit(allocator);
        self.database = .{};
        self.guest_exports.deinit(allocator);
        self.tls_registry.deinit(allocator);
        if (self.address_space) |*space| space.deinit();
        self.address_space = null;
        self.allocator = null;
        self.initialized = false;
    }

    /// Installs or removes the CPU-dispatch adapter used by guest pthreads.
    /// The adapter receives a ready-to-use guest FS base for every new thread.
    pub fn setThreadBackend(
        self: *Runtime,
        backend: ?hle.libs.kernel_threading.Backend,
    ) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        if (self.cpu_dispatcher.isInitialized()) return error.DispatcherBusy;
        self.thread_manager.setBackend(backend);
    }

    /// Attaches the process CPU dispatcher to libkernel pthreads. The bridge is
    /// responsible only for machine entry/exit and guest FS translation; host
    /// workers, waits, callbacks, joins, and exits are owned by the dispatcher.
    pub fn enableCpuDispatcher(
        self: *Runtime,
        io: std.Io,
        bridge: cpu.Bridge,
    ) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        if (self.native_cpu_bridge.isInitialized()) return error.DispatcherBusy;
        hle.libs.kernel_runtime.attachIo(io);
        return self.cpu_dispatcher.init(
            self.allocator.?,
            io,
            &self.thread_manager,
            bridge,
        );
    }

    /// Enables direct Windows x86-64 execution using the runtime-owned guest
    /// address space. The native bridge validates executable entries and guest
    /// stacks, installs FS only inside the assembly boundary, and restores the
    /// complete Win64 nonvolatile state before returning to Zig.
    pub fn enableNativeCpuDispatcher(self: *Runtime, io: std.Io) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        hle.libs.kernel_runtime.attachIo(io);
        try self.native_cpu_bridge.init(self.allocator.?, &self.address_space.?);
        errdefer self.native_cpu_bridge.deinit();
        try self.cpu_dispatcher.init(
            self.allocator.?,
            io,
            &self.thread_manager,
            self.native_cpu_bridge.bridge(),
        );
    }

    pub fn disableCpuDispatcher(self: *Runtime) void {
        self.cpu_dispatcher.deinit();
        self.native_cpu_bridge.deinit();
    }

    /// Returns the latest guest fault contained by the runtime-owned native
    /// bridge. Custom CPU bridges keep their own diagnostic channel.
    pub fn lastNativeFault(self: *Runtime) ?cpu.FaultRecord {
        if (!self.initialized or !self.native_cpu_bridge.isInitialized()) return null;
        return self.native_cpu_bridge.lastFault();
    }

    /// Prepares TCB/DTV state for the initial guest execution context.
    pub fn prepareInitialThread(
        self: *Runtime,
        name: []const u8,
    ) Error!hle.libs.kernel_threading.PreparedThread {
        if (!self.initialized) return Error.NotInitialized;
        return self.thread_manager.prepareInitialThread(name);
    }

    pub fn releaseInitialThread(
        self: *Runtime,
        handle: hle.libs.kernel_threading.ThreadHandle,
    ) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        return self.thread_manager.releaseInitialThread(handle);
    }

    /// Associates the current host worker with a guest pthread identity.
    /// The CPU backend separately installs the accompanying ThreadContext.
    pub fn enterGuestThread(
        self: *Runtime,
        handle: hle.libs.kernel_threading.ThreadHandle,
    ) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        return self.thread_manager.enter(handle);
    }

    /// Clears the current host worker's guest pthread identity.
    pub fn leaveGuestThread(self: *Runtime) void {
        if (!self.initialized) return;
        self.thread_manager.leave();
    }

    /// Runs POSIX TLS-key destructors before a naturally returning guest entry
    /// point leaves its FS context. `scePthreadExit` performs this step itself.
    pub fn runCurrentThreadDestructors(self: *Runtime) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        return self.thread_manager.runSpecificDestructors();
    }

    /// Enters a prepared initial guest thread through the active dispatcher.
    pub fn dispatchGuestEntry(
        self: *Runtime,
        prepared: hle.libs.kernel_threading.PreparedThread,
        entry_point: u64,
        arguments: []const u64,
    ) Error!u64 {
        if (!self.initialized) return Error.NotInitialized;
        return self.cpu_dispatcher.dispatchInitial(prepared, entry_point, arguments);
    }

    /// Runs executable preinitializers, dependency-ordered module
    /// initializers, and executable initializers before building the fixed PS5
    /// entry parameter block and dispatching the process entry point.
    pub fn dispatchProcess(
        self: *Runtime,
        prepared: hle.libs.kernel_threading.PreparedThread,
        executable: *loader.MappedImage,
        options: ProcessOptions,
    ) Error!u64 {
        if (!self.initialized) return Error.NotInitialized;
        if (!self.cpu_dispatcher.isInitialized()) return error.NotInitialized;
        if (!self.ownsImage(executable)) return error.InvalidArgument;
        for (options.modules) |module| {
            if (!self.ownsImage(module)) return error.InvalidArgument;
        }

        if (!executable.preinitializers_ran) {
            try self.runInitializerList(prepared, executable.preinit_functions.items);
            executable.preinitializers_ran = true;
        }
        for (options.modules) |module| {
            if (module.initializers_ran) continue;
            try self.runInitializerList(prepared, module.init_functions.items);
            module.initializers_ran = true;
        }
        if (!executable.initializers_ran) {
            try self.runInitializerList(prepared, executable.init_functions.items);
            executable.initializers_ran = true;
        }

        const layout = try process.buildEntryLayout(
            &self.address_space.?,
            prepared.stack_address,
            prepared.stack_size,
            options.entry,
        );
        return self.cpu_dispatcher.dispatchInitialAtStack(
            prepared,
            executable.entry_point,
            &.{ layout.params_address, options.exit_handler },
            layout.stack_pointer,
        );
    }

    /// Reports a child result after the backend has left its guest FS context.
    pub fn completeGuestThread(
        self: *Runtime,
        handle: hle.libs.kernel_threading.ThreadHandle,
        result: u64,
    ) Error!void {
        if (!self.initialized) return Error.NotInitialized;
        return self.thread_manager.complete(handle, result);
    }

    fn ownsImage(self: *Runtime, image: *const loader.MappedImage) bool {
        return image.address_space == &self.address_space.?;
    }

    fn runInitializerList(
        self: *Runtime,
        prepared: hle.libs.kernel_threading.PreparedThread,
        functions: []const u64,
    ) Error!void {
        for (functions) |entry_point| {
            _ = try self.cpu_dispatcher.dispatchInitializer(
                prepared,
                entry_point,
                &.{ 0, 0, 0 },
            );
        }
    }

    /// Parses and loads one module through the complete runtime path.
    pub fn loadModule(
        self: *Runtime,
        image_bytes: []const u8,
        options: loader.LoadOptions,
    ) Error!loader.MappedImage {
        if (!self.initialized) return Error.NotInitialized;
        const allocator = self.allocator.?;
        const image = try loader.parseImage(image_bytes);
        var dynamic_info = try loader.parseDynamic(allocator, image);
        defer dynamic_info.deinit(allocator);

        var resolver_context = ResolverContext{
            .database = &self.database,
            .tls_registry = &self.tls_registry,
            .guest_exports = &self.guest_exports,
        };
        const resolver = loader.Resolver{
            .context = &resolver_context,
            .resolve_fn = resolveImport,
            .resolve_tls_fn = resolveTlsImport,
        };
        var load_options = options;
        load_options.tls_registry = &self.tls_registry;
        load_options.guest_export_registry = &self.guest_exports;
        const mapped = try loader.loadImage(
            allocator,
            &self.address_space.?,
            image,
            &dynamic_info,
            resolver,
            load_options,
        );
        if (mapped.process_param_range) |range| {
            hle.libs.kernel_runtime.attachProcessParam(range.start);
        }
        return mapped;
    }

    /// Discovers adjacent PRX/SRPX files, maps the complete reachable graph,
    /// publishes every guest export, then relocates in dependency-first order.
    pub fn loadModuleGraph(
        self: *Runtime,
        io: std.Io,
        executable_path: []const u8,
        options: ModuleGraphOptions,
    ) !ModuleGraph {
        if (!self.initialized) return Error.NotInitialized;
        const directory_name = std.fs.path.dirname(executable_path) orelse ".";
        const executable_name = std.fs.path.basename(executable_path);
        var directory = try std.Io.Dir.cwd().openDir(io, directory_name, .{ .iterate = true });
        defer directory.close(io);

        var resolver_context = ResolverContext{
            .database = &self.database,
            .tls_registry = &self.tls_registry,
            .guest_exports = &self.guest_exports,
        };
        const resolver = loader.Resolver{
            .context = &resolver_context,
            .resolve_fn = resolveImport,
            .resolve_tls_fn = resolveTlsImport,
        };
        hle.libs.kernel_runtime.attachIo(io);
        var graph = try module_graph.loadFromDir(
            self.allocator.?,
            io,
            directory,
            executable_name,
            &self.address_space.?,
            &self.tls_registry,
            &self.guest_exports,
            resolver,
            options,
        );
        if (graph.executable().process_param_range) |range| {
            hle.libs.kernel_runtime.attachProcessParam(range.start);
        }
        return graph;
    }
};

const ResolverContext = struct {
    database: *const hle.Database,
    tls_registry: *loader.TlsRegistry,
    guest_exports: *loader.GuestExportRegistry,
};

fn resolveImport(raw_context: ?*anyopaque, import: *const loader.Import) ?u64 {
    const raw = raw_context orelse return null;
    const context: *ResolverContext = @ptrCast(@alignCast(raw));
    const symbol_type = toHleSymbolType(import.symbol_type);

    if (context.guest_exports.resolveExact(import)) |address| return address;

    if (import.id.len == hle.nid.encoded_len and
        import.library != null and import.library_version != null and import.module != null)
    {
        var id: hle.nid.Encoded = undefined;
        @memcpy(&id, import.id);
        const key = hle.symbols.Key{
            .id = id,
            .library = .{
                .name = import.library.?,
                .version = @intCast(import.library_version.?),
            },
            .module = .{ .name = import.module.? },
            .type = symbol_type,
        };
        if (context.database.find(key)) |symbol| return symbol.address;
    }

    if (context.guest_exports.resolveById(import)) |address| return address;
    const symbol = context.database.findById(import.id, symbol_type) orelse return null;
    return symbol.address;
}

fn resolveTlsImport(
    raw_context: ?*anyopaque,
    import: *const loader.Import,
) ?loader.TlsResolvedSymbol {
    const raw = raw_context orelse return null;
    const context: *ResolverContext = @ptrCast(@alignCast(raw));
    return context.tls_registry.resolve(import);
}

fn toHleSymbolType(symbol_type: loader.symbols.Type) hle.SymbolType {
    return switch (symbol_type) {
        .func => .function,
        .object => .object,
        .tls => .tls_module,
        else => .no_type,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const ProcessTestBridge = struct {
    entries: [16]u64 = [_]u64{0} ** 16,
    kinds: [16]cpu.EntryKind = [_]cpu.EntryKind{.process_entry} ** 16,
    count: usize = 0,
    final_arguments: [cpu.maximum_arguments]u64 = [_]u64{0} ** cpu.maximum_arguments,
    final_argument_count: u8 = 0,
    final_stack_pointer: ?u64 = null,

    fn execute(raw: ?*anyopaque, request: cpu.ExecuteRequest) cpu.ExecutionError!u64 {
        const self: *ProcessTestBridge = @ptrCast(@alignCast(raw.?));
        if (self.count >= self.entries.len) return error.ExecutionFailed;
        self.entries[self.count] = request.entry_point;
        self.kinds[self.count] = request.kind;
        self.count += 1;
        if (request.kind == .module_initializer and
            (request.argument_count != 3 or request.arguments[0] != 0 or
                request.arguments[1] != 0 or request.arguments[2] != 0))
        {
            return error.ExecutionFailed;
        }
        if (request.kind == .process_entry) {
            self.final_arguments = request.arguments;
            self.final_argument_count = request.argument_count;
            self.final_stack_pointer = request.stack_pointer;
        }
        return request.entry_point;
    }

    fn bridge(self: *ProcessTestBridge) cpu.Bridge {
        return .{ .context = self, .execute_fn = &execute };
    }
};

test "runtime owns one address space and loads a fixed module" {
    const payload = "runtime image";
    const offset = loader.elf.TestImage.payloadOffset(1);
    const segments = [_]loader.ProgramHeader{.{
        .type = @intFromEnum(loader.SegmentType.load),
        .flags = 0x4,
        .offset = offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = payload.len,
        .memsz = memory.page_size,
        .@"align" = memory.page_size,
    }};
    var fixture = try loader.elf.TestImage.build(
        testing.allocator,
        .sce_dynexec,
        &segments,
        payload,
    );
    defer fixture.deinit(testing.allocator);

    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();

    var mapped = try runtime.loadModule(
        fixture.bytes(),
        .{ .load_bias = memory.system_managed.start },
    );
    defer mapped.deinit();

    var output: [payload.len]u8 = undefined;
    try runtime.address_space.?.read(memory.system_managed.start, &output);
    try testing.expectEqualStrings(payload, &output);
    try testing.expect(runtime.database.count() != 0);
}

test "runtime registers PT_TLS and unregisters it with the mapped image" {
    const payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const offset = loader.elf.TestImage.payloadOffset(2);
    const segments = [_]loader.ProgramHeader{
        .{
            .type = @intFromEnum(loader.SegmentType.load),
            .flags = 0x6,
            .offset = offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = payload.len,
            .memsz = memory.page_size,
            .@"align" = memory.page_size,
        },
        .{
            .type = @intFromEnum(loader.SegmentType.tls),
            .flags = 0x4,
            .offset = offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = payload.len,
            .memsz = 0x20,
            .@"align" = 0x10,
        },
    };
    var fixture = try loader.elf.TestImage.build(
        testing.allocator,
        .sce_dynexec,
        &segments,
        &payload,
    );
    defer fixture.deinit(testing.allocator);

    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();
    var mapped = try runtime.loadModule(
        fixture.bytes(),
        .{ .load_bias = memory.system_managed.start },
    );

    const tls_module = mapped.tls_module orelse return error.TestExpectedTlsModule;
    try testing.expectEqual(@as(u64, 1), tls_module.id);
    try testing.expectEqual(@as(u64, 0x20), tls_module.static_offset);
    try testing.expectEqual(@as(usize, 1), runtime.tls_registry.count());

    try mapped.unload();
    try testing.expectEqual(@as(usize, 0), runtime.tls_registry.count());
}

test "runtime resolves ordinary imports to mapped guest exports before HLE" {
    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();
    _ = try runtime.guest_exports.register(testing.allocator, &.{.{
        .id = "guest-libc",
        .library = "libc",
        .library_version = 1,
        .module = "libc",
        .symbol_type = .func,
        .address = 0x08_1234_5000,
    }});
    var context = ResolverContext{
        .database = &runtime.database,
        .tls_registry = &runtime.tls_registry,
        .guest_exports = &runtime.guest_exports,
    };
    const import = loader.Import{
        .id = "guest-libc",
        .library = "libc",
        .library_version = 1,
        .module = "libc",
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .func,
        .relocation_type = .jump_slot,
        .table = .plt,
        .target_offset = 0,
        .addend = 0,
    };
    try testing.expectEqual(
        @as(?u64, 0x08_1234_5000),
        resolveImport(&context, &import),
    );
}

test "runtime prepares and identifies the initial guest thread" {
    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();
    _ = try runtime.tls_registry.register(testing.allocator, .{
        .initial_image = &.{ 0xde, 0xad },
        .memory_size = 0x20,
        .alignment = 0x10,
    });

    const prepared = try runtime.prepareInitialThread("MainThread");
    defer runtime.releaseInitialThread(prepared.handle) catch {};
    try testing.expect(prepared.context.fs_base != 0);
    try testing.expect(prepared.context.dtv_address > prepared.context.fs_base);

    try runtime.enterGuestThread(prepared.handle);
    defer runtime.leaveGuestThread();
    try testing.expectEqual(
        prepared.handle,
        hle.libs.kernel_threading.scePthreadSelf(),
    );
}

test "runtime owns the optional native CPU bridge lifecycle" {
    if (!cpu.NativeBridge.isSupported()) return error.SkipZigTest;

    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();

    try runtime.enableNativeCpuDispatcher(testing.io);
    try testing.expect(runtime.cpu_dispatcher.isInitialized());
    try testing.expect(runtime.native_cpu_bridge.isInitialized());

    runtime.disableCpuDispatcher();
    try testing.expect(!runtime.cpu_dispatcher.isInitialized());
    try testing.expect(!runtime.native_cpu_bridge.isInitialized());
}

test "process dispatch orders initializers and builds the PS5 entry parameters" {
    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();
    var bridge = ProcessTestBridge{};
    try runtime.enableCpuDispatcher(testing.io, bridge.bridge());

    var module = loader.MappedImage{
        .address_space = &runtime.address_space.?,
        .allocator = testing.allocator,
        .load_bias = 0,
        .entry_point = 0x200,
        .relocation_stats = .{},
    };
    defer module.deinit();
    try module.init_functions.append(testing.allocator, 0x201);

    var executable = loader.MappedImage{
        .address_space = &runtime.address_space.?,
        .allocator = testing.allocator,
        .load_bias = 0,
        .entry_point = 0x400,
        .relocation_stats = .{},
    };
    defer executable.deinit();
    try executable.preinit_functions.append(testing.allocator, 0x101);
    try executable.preinit_functions.append(testing.allocator, 0x102);
    try executable.init_functions.append(testing.allocator, 0x301);
    try executable.init_functions.append(testing.allocator, 0x302);

    const prepared = try runtime.prepareInitialThread("process-main");
    defer runtime.releaseInitialThread(prepared.handle) catch {};
    const result = try runtime.dispatchProcess(
        prepared,
        &executable,
        .{
            .entry = .{
                .image_name = "eboot.bin",
                .arguments = &.{ "-safe", "profile=1" },
            },
            .exit_handler = 0x55,
            .modules = &.{&module},
        },
    );

    try testing.expectEqual(@as(u64, 0x400), result);
    try testing.expectEqualSlices(
        u64,
        &.{ 0x101, 0x102, 0x201, 0x301, 0x302, 0x400 },
        bridge.entries[0..bridge.count],
    );
    for (bridge.kinds[0..5]) |kind| {
        try testing.expectEqual(cpu.EntryKind.module_initializer, kind);
    }
    try testing.expectEqual(cpu.EntryKind.process_entry, bridge.kinds[5]);
    try testing.expectEqual(@as(u8, 2), bridge.final_argument_count);
    try testing.expectEqual(@as(u64, 0x55), bridge.final_arguments[1]);
    try testing.expectEqual(bridge.final_arguments[0], bridge.final_stack_pointer.?);
    try testing.expect(executable.preinitializers_ran);
    try testing.expect(executable.initializers_ran);
    try testing.expect(module.initializers_ran);

    var encoded: [@sizeOf(process.EntryParams)]u8 = undefined;
    try runtime.address_space.?.read(bridge.final_arguments[0], &encoded);
    const params = std.mem.bytesToValue(process.EntryParams, &encoded);
    try testing.expectEqual(@as(u32, 3), params.argc);
    try expectRuntimeGuestString(&runtime.address_space.?, params.argv[0], "eboot.bin");
    try expectRuntimeGuestString(&runtime.address_space.?, params.argv[1], "-safe");
    try expectRuntimeGuestString(&runtime.address_space.?, params.argv[2], "profile=1");

    bridge.count = 0;
    _ = try runtime.dispatchProcess(prepared, &executable, .{ .modules = &.{&module} });
    try testing.expectEqual(@as(usize, 1), bridge.count);
    try testing.expectEqual(@as(u64, 0x400), bridge.entries[0]);
}

test "native process entry reads argc from the generated parameter block" {
    if (!cpu.NativeBridge.isSupported()) return error.SkipZigTest;

    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();
    try runtime.enableNativeCpuDispatcher(testing.io);

    const code_address = memory.system_managed.start;
    try runtime.address_space.?.mapFixed(
        code_address,
        memory.page_size,
        .read_write,
        .module,
        null,
    );
    // mov eax, dword ptr [rdi]; add rax, rsi; ret
    try runtime.address_space.?.write(
        code_address,
        &.{ 0x8b, 0x07, 0x48, 0x01, 0xf0, 0xc3 },
    );
    // mov rax, qword ptr [0]; ret
    try runtime.address_space.?.write(
        code_address + 0x20,
        &.{ 0x48, 0x8b, 0x04, 0x25, 0, 0, 0, 0, 0xc3 },
    );
    try runtime.address_space.?.protect(
        code_address,
        memory.page_size,
        .read_execute,
    );

    var executable = loader.MappedImage{
        .address_space = &runtime.address_space.?,
        .allocator = testing.allocator,
        .load_bias = code_address,
        .entry_point = code_address,
        .relocation_stats = .{},
    };
    try executable.ranges.append(testing.allocator, .{
        .start = code_address,
        .end = code_address + memory.page_size,
    });
    defer executable.deinit();

    const prepared = try runtime.prepareInitialThread("native-process");
    defer runtime.releaseInitialThread(prepared.handle) catch {};
    const result = try runtime.dispatchProcess(
        prepared,
        &executable,
        .{
            .entry = .{ .arguments = &.{"--test"} },
            .exit_handler = 0x40,
        },
    );
    try testing.expectEqual(@as(u64, 0x42), result);

    executable.entry_point = code_address + 0x20;
    try testing.expectError(
        error.GuestFault,
        runtime.dispatchProcess(prepared, &executable, .{}),
    );
    const fault = runtime.lastNativeFault().?;
    try testing.expectEqual(cpu.FaultKind.access_violation, fault.info.kind);
    try testing.expectEqual(cpu.FaultAccess.read, fault.info.access);
    try testing.expectEqual(code_address + 0x20, fault.info.registers.rip);
    try testing.expectEqual(@as(u64, 0), fault.info.memory_address);
}

fn expectRuntimeGuestString(
    address_space: *memory.AddressSpace,
    address: u64,
    expected: []const u8,
) !void {
    var bytes: [32]u8 = [_]u8{0} ** 32;
    try address_space.read(address, bytes[0 .. expected.len + 1]);
    try testing.expectEqualStrings(expected, bytes[0..expected.len]);
    try testing.expectEqual(@as(u8, 0), bytes[expected.len]);
}

test {
    _ = module_graph;
}
