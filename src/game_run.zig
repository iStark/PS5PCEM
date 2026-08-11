// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Loads, initializes, and enters a decrypted PS5 title through the native
//! Windows x86-64 guest bridge.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const runtime = @import("runtime");
const loader = @import("loader");
const vulkan = @import("vulkan");
const window = @import("window");

const usage =
    \\game-run [--app0 <content-directory>] <eboot.bin>
    \\
    \\Loads and relocates the adjacent PRX graph, runs its initializers, then
    \\enters the title process. --app0 supplies full game content when eboot.bin
    \\comes from a sparse patch directory. Direct execution requires Windows x86-64.
    \\
;

fn reportUnresolvedImport(_: ?*anyopaque, diagnostic: runtime.module_graph.UnresolvedImport) void {
    std.debug.print("  unresolved {s}: {s} {s} {s}\n", .{
        diagnostic.path,
        diagnostic.import.id,
        diagnostic.import.library orelse diagnostic.import.library_code,
        @tagName(diagnostic.import.symbol_type),
    });
}

fn resolveVideoOutBuffer(_: ?*anyopaque, flip: gpu.state.Flip) ?vulkan.DisplayBuffer {
    const registration = runtime.firmware.video_out.resolveFlip(flip) orelse return null;
    return .{
        .address = registration.data_address,
        .width = registration.attribute.width,
        .height = registration.attribute.height,
        .pitch_in_pixels = registration.attribute.pitch_in_pixels,
        .tiling_mode = registration.attribute.tiling_mode,
    };
}

fn updateHostWindowFps(context: ?*anyopaque, fps_tenths: u32) void {
    const host_window: *window.HostWindow = @ptrCast(@alignCast(context orelse return));
    host_window.updateFps(fps_tenths);
}

fn appendUnityDeferredModules(
    allocator: std.mem.Allocator,
    io: std.Io,
    title_root: []const u8,
    modules: *std.ArrayList([]const u8),
) !void {
    var directory = std.Io.Dir.cwd().openDir(io, title_root, .{}) catch return;
    defer directory.close(io);
    const candidates = [_][]const u8{
        "Media/Plugins/lib_burst_generated.prx",
        "Media/Plugins/SaveData.prx",
        "Media/Plugins/PSN.prx",
    };
    for (candidates) |path| {
        _ = directory.statFile(io, path, .{}) catch continue;
        try modules.append(allocator, path);
    }
}

fn reportRelocation(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    node: *runtime.module_graph.Module,
    target: u64,
) !void {
    const mapped = &node.mapped.?;
    if (target < mapped.load_bias) return;
    const target_offset = target - mapped.load_bias;
    try writer.print("  rip-relative target: 0x{x} (image+0x{x})\n", .{ target, target_offset });
    var encoded_value: [8]u8 = undefined;
    if (mapped.address_space.read(target, &encoded_value)) |_| {
        try writer.print("  current target value: 0x{x}\n", .{std.mem.readInt(u64, &encoded_value, .little)});
    } else |_| {}

    var imports = loader.collectImports(allocator, node.image, &node.dynamic_info) catch return;
    defer imports.deinit(allocator);
    for (imports.items.items) |import| {
        if (import.target_offset != target_offset) continue;
        try writer.print("  referenced import: {s} {s}\n", .{
            import.id,
            import.library orelse import.library_code,
        });
    }

    const tables = [_]struct {
        bytes: []const u8,
        kind: loader.relocations.TableKind,
    }{
        .{
            .bytes = node.dynamic_info.tableData(
                node.image,
                node.dynamic_info.rela_offset,
                node.dynamic_info.rela_size,
            ) catch &.{},
            .kind = .general,
        },
        .{
            .bytes = node.dynamic_info.tableData(
                node.image,
                node.dynamic_info.jmprel_offset,
                node.dynamic_info.jmprel_size,
            ) catch &.{},
            .kind = .plt,
        },
    };
    for (tables) |table_data| {
        const table = loader.relocations.Table.init(table_data.bytes, table_data.kind) catch continue;
        for (table.entries) |relocation| {
            if (relocation.offset != target_offset) continue;
            try writer.print("  relocation: {s}, symbol={d}, addend={d}\n", .{
                @tagName(relocation.relocationType()),
                relocation.symbolIndex(),
                relocation.addend,
            });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    if (!try run(init)) std.process.exit(1);
}

fn run(init: std.process.Init) !bool {
    const io = init.io;
    const startup_arena = init.arena.allocator();
    // The process init arena intentionally ignores individual frees. That is
    // useful for short-lived CLI parsing but disastrous for a long-running
    // renderer: temporary uploads, readbacks, tiled frames, and grown array
    // capacities would all remain committed until process exit. Use the
    // thread-safe freeing allocator for runtime-owned state instead.
    const allocator = std.heap.smp_allocator;

    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(startup_arena);
    const has_app0_override = args.len == 4 and std.mem.eql(u8, args[1], "--app0");
    if (args.len != 2 and !has_app0_override) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return false;
    }
    const executable_path = if (has_app0_override) args[3] else args[1];
    const title_root = if (has_app0_override)
        args[2]
    else
        std.fs.path.dirname(executable_path) orelse ".";

    var emu = runtime.Runtime{};
    try emu.init(allocator);
    defer emu.deinit();

    var preload_modules: std.ArrayList([]const u8) = .empty;
    defer preload_modules.deinit(allocator);
    var preload_text: ?[]u8 = null;
    defer if (preload_text) |text| allocator.free(text);
    if (init.minimal.environ.getAlloc(allocator, "PS5_PRELOAD")) |text| {
        preload_text = text;
        var parts = std.mem.splitScalar(u8, text, ';');
        while (parts.next()) |part| {
            const path = std.mem.trim(u8, part, " \t\r\n");
            if (path.len != 0) try preload_modules.append(allocator, path);
        }
    } else |_| {}

    var deferred_modules: std.ArrayList([]const u8) = .empty;
    defer deferred_modules.deinit(allocator);
    var deferred_text: ?[]u8 = null;
    defer if (deferred_text) |text| allocator.free(text);
    if (init.minimal.environ.getAlloc(allocator, "PS5_DEFERRED_MODULES")) |text| {
        deferred_text = text;
        var parts = std.mem.splitScalar(u8, text, ';');
        while (parts.next()) |part| {
            const path = std.mem.trim(u8, part, " \t\r\n");
            if (path.len != 0) try deferred_modules.append(allocator, path);
        }
    } else |_| {
        // These Unity plug-ins are loaded explicitly after startup rather than
        // through DT_NEEDED. Map them ahead of guest execution, while leaving
        // their constructors deferred until LoadStartModule supplies the real
        // argument block. The environment variable remains the override for
        // uncommon title-specific modules.
        try appendUnityDeferredModules(allocator, io, title_root, &deferred_modules);
    }

    var graph = emu.loadModuleGraph(io, executable_path, .{
        .preload_modules = preload_modules.items,
        .deferred_modules = deferred_modules.items,
        .diagnostics = .{ .unresolved_fn = &reportUnresolvedImport },
    }) catch |err| {
        try stderr.print("cannot link {s}: {s}\n", .{ executable_path, @errorName(err) });
        try stderr.flush();
        return false;
    };
    defer graph.deinit();

    // Must precede any guest execution: a throwing title asks the kernel which
    // module owns each return address, and without an answer its runtime finds
    // no handler and terminates instead of recovering.
    const unwind_modules = try graph.publishUnwindModules(allocator);
    defer {
        runtime.firmware.unwind.detach();
        allocator.free(unwind_modules);
    }

    // Titles load some of their own modules by path once running; everything is
    // already mapped, so the request has to resolve to what exists.
    const loaded_modules = try graph.publishModules(allocator, &emu.guest_exports);
    defer {
        runtime.firmware.modules.detach();
        allocator.free(loaded_modules);
    }

    // The directory holding the executable is what a title sees as /app0.
    var content = std.Io.Dir.cwd().openDir(io, title_root, .{}) catch |err| {
        try stderr.print("cannot open {s}: {s}\n", .{ title_root, @errorName(err) });
        try stderr.flush();
        return false;
    };
    defer content.close(io);
    runtime.firmware.filesystem.attach(io, content);
    defer runtime.firmware.filesystem.detach();

    // A contained fault prints the retained calls afterwards, but a process
    // that dies outright takes the buffer with it. This is the escape hatch for
    // those, and it is far too noisy for anything else.
    //
    // The value may name which entry points to print, as comma-separated
    // fragments of their names. That is not a convenience: printing every call
    // costs more than the calls do, so a title that would reach its render loop
    // in a second never gets there under a full trace — and the render loop is
    // exactly what one wants to watch. Anything other than a bare "1" is read
    // as a filter.
    if (init.minimal.environ.getAlloc(allocator, "PS5_TRACE")) |text| {
        defer allocator.free(text);
        const request = std.mem.trim(u8, text, " \t\r\n");
        if (request.len != 0) {
            runtime.firmware.trace.setLive(true);
            if (!std.mem.eql(u8, request, "1")) {
                runtime.firmware.trace.setLiveFilter(request);
                try out.print("  tracing only calls matching: {s}\n", .{request});
            }
        }
    } else |_| {}

    if (init.minimal.environ.getAlloc(allocator, "PS5_TRACE_FAILURES")) |text| {
        defer allocator.free(text);
        const request = std.mem.trim(u8, text, " \t\r\n");
        if (request.len != 0 and !std.mem.eql(u8, request, "0")) {
            runtime.firmware.trace.setLive(true);
            runtime.firmware.trace.setLiveFailuresOnly(true);
            try out.print("  tracing failed firmware calls only\n", .{});
        }
    } else |_| {}

    // Arms a one-shot snapshot of the guest stack at one firmware call, named by
    // its number in the trace. The trace says which calls a title made; this
    // says which of the title's own code made one of them, which is the only
    // question left once a call is seen to repeat thousands of times.
    if (init.minimal.environ.getAlloc(allocator, "PS5_STACK_AT")) |text| {
        defer allocator.free(text);
        const request = std.mem.trim(u8, text, " \t\r\n");
        const separator = std.mem.lastIndexOfScalar(u8, request, ':');
        const name = if (separator) |at| request[0..at] else request;
        const occurrence = if (separator) |at|
            std.fmt.parseInt(u64, request[at + 1 ..], 10) catch 0
        else
            1;
        if (occurrence == 0 or name.len == 0) {
            try stderr.print(
                "PS5_STACK_AT wants <entry point>[:<call number>], not {s}\n",
                .{request},
            );
            try stderr.flush();
        } else {
            runtime.firmware.trace.captureStackAt(name, occurrence);
        }
    } else |_| {}

    // Live GPU submissions use the same serialized PM4 scheduler as tracing.
    // The host renderer stays optional so loader/CPU diagnostics remain useful
    // on machines without a Vulkan presentation device.
    var host_window = window.HostWindow{};
    var window_initialized = false;
    var renderer: vulkan.Renderer = undefined;
    var renderer_initialized = false;
    defer {
        // Stop every guest worker before taking away callbacks it may still be
        // executing, then release Vulkan before destroying the HWND surface.
        emu.disableCpuDispatcher();
        runtime.firmware.libs.agc_submit.attachBackend(null);
        if (renderer_initialized) renderer.deinit();
        if (window_initialized) host_window.deinit();
    }

    const force_headless = init.minimal.environ.containsUnempty(allocator, "PS5_HEADLESS") catch false;
    const show_fps = init.minimal.environ.containsUnempty(allocator, "PS5_SHOW_FPS") catch false;
    const enable_vulkan_validation = init.minimal.environ.containsUnempty(allocator, "PS5_VULKAN_VALIDATION") catch false;
    const capture_first_graphics_frame = init.minimal.environ.containsUnempty(allocator, "PS5_CAPTURE_FIRST_FRAME") catch false;
    const force_probe_fragment = init.minimal.environ.containsUnempty(allocator, "PS5_PROBE_FRAGMENT_COLOR") catch false;
    const force_probe_fragment_texture = init.minimal.environ.containsUnempty(allocator, "PS5_PROBE_FRAGMENT_TEXTURE") catch false;
    const force_probe_fragment_parameter = init.minimal.environ.containsUnempty(allocator, "PS5_PROBE_FRAGMENT_PARAMETER") catch false;
    const force_probe_fragment_ui = init.minimal.environ.containsUnempty(allocator, "PS5_PROBE_FRAGMENT_UI") catch false;
    const skip_compute_dispatches = init.minimal.environ.containsUnempty(allocator, "PS5_SKIP_COMPUTE") catch false;
    const translate_compute_only = init.minimal.environ.containsUnempty(allocator, "PS5_COMPUTE_TRANSLATE_ONLY") catch false;
    if (builtin.os.tag == .windows and !force_headless) live_gpu: {
        host_window.init(1280, 720) catch |err| {
            try stderr.print("live Vulkan window unavailable: {s}; continuing headless\n", .{@errorName(err)});
            try stderr.flush();
            break :live_gpu;
        };
        window_initialized = true;
        const native = host_window.nativeHandle() orelse {
            try stderr.writeAll("live Vulkan window returned no native handle; continuing headless\n");
            try stderr.flush();
            break :live_gpu;
        };
        renderer = vulkan.Renderer.init(allocator, .{
            .enable_validation = enable_vulkan_validation,
            .capture_first_graphics_frame = capture_first_graphics_frame,
            .force_probe_fragment = force_probe_fragment,
            .force_probe_fragment_texture = force_probe_fragment_texture,
            .force_probe_fragment_parameter = force_probe_fragment_parameter,
            .force_probe_fragment_ui = force_probe_fragment_ui,
            .skip_compute_dispatches = skip_compute_dispatches,
            .translate_compute_only = translate_compute_only,
            .native_window = .{
                .instance = native.instance,
                .window = native.window,
                .width = native.width,
                .height = native.height,
            },
        }) catch |err| {
            try stderr.print("live Vulkan renderer unavailable: {s}; continuing headless\n", .{@errorName(err)});
            try stderr.flush();
            host_window.deinit();
            window_initialized = false;
            break :live_gpu;
        };
        renderer_initialized = true;
        const presentation_sink = renderer.windowPresentationSink();
        renderer.setPresentationSink(presentation_sink);
        if (show_fps) renderer.setFrameRateSink(.{
            .context = &host_window,
            .update = updateHostWindowFps,
        });
        renderer.setDisplayBufferResolver(.{
            .context = null,
            .resolve = resolveVideoOutBuffer,
        });
        const guest_memory = vulkan.GuestMemory{
            .context = null,
            .read = runtime.firmware.libs.agc_submit.readGuestMemory,
            .write = runtime.firmware.libs.agc_submit.writeGuestMemory,
            .shader_header = runtime.firmware.libs.agc_submit.findShaderHeader,
        };
        runtime.firmware.libs.agc_submit.attachBackend(renderer.dcbBackend(guest_memory));
        try out.print("  Vulkan  {s} ({d}x{d} VideoOut window)\n", .{
            renderer.device_info.name(),
            native.width,
            native.height,
        });
    }

    try emu.enableNativeCpuDispatcher(io);
    const prepared = try emu.prepareInitialThread("eboot-main");
    defer emu.releaseInitialThread(prepared.handle) catch {};

    try out.print("loaded {s}\n", .{executable_path});
    try out.print("  modules {d}\n", .{graph.moduleCount()});
    try out.print("  entry   0x{x}\n", .{graph.executable().entry_point});
    for (graph.nodes.items) |*node| {
        const image = &node.mapped.?;
        try out.print("  image   0x{x} {s}, init={d}\n", .{
            image.load_bias,
            node.path,
            image.init_functions.items.len,
        });
        for (image.init_functions.items) |initializer| {
            try out.print("    initializer 0x{x}\n", .{initializer});
        }
    }
    try out.writeAll("entering guest process\n");
    try out.flush();

    const result = emu.dispatchProcess(
        prepared,
        graph.executable(),
        .{
            .entry = .{ .image_name = std.fs.path.basename(executable_path) },
            .modules = graph.modules(),
        },
    ) catch |err| {
        // Ask guest I/O hot paths (AGC suspendPoint spam via `_write`) to exit
        // before the diagnostic dump; otherwise those workers keep burning cores
        // while the report is formatted.
        runtime.firmware.libs.kernel_runtime.requestGuestStop();

        // Symbol-attributed report first: it names the module and, for a call
        // through a null pointer, the caller recovered from the stack. The raw
        // dumps below stay as supporting detail for cases it cannot classify.
        if (graph.buildSymbolMap(allocator)) |built| {
            var map = built;
            defer map.deinit(allocator);
            _ = emu.writeLastFault(&map, stderr) catch {};
        } else |_| {}

        if (emu.lastNativeFault()) |fault| {
            try stderr.print(
                "guest fault: {s}/{s}, code=0x{x}, dispatch=0x{x}, rip=0x{x}, address=0x{x}, rsp=0x{x}\n",
                .{
                    @tagName(fault.info.kind),
                    @tagName(fault.info.access),
                    fault.info.exception_code,
                    emu.lastDispatchedEntry(),
                    fault.info.instruction_address,
                    fault.info.memory_address,
                    fault.info.registers.rsp,
                },
            );
            var stack_words: [8]u64 = undefined;
            if (emu.address_space.?.read(fault.info.registers.rsp, std.mem.sliceAsBytes(&stack_words))) |_| {
                try stderr.writeAll("  stack:");
                for (stack_words) |word| try stderr.print(" 0x{x}", .{word});
                try stderr.writeByte('\n');
                for (stack_words[0..3]) |return_address| {
                    for (graph.nodes.items) |*node| {
                        const image = &node.mapped.?;
                        if (return_address < image.load_bias + 16) continue;
                        const frame_code = node.image.virtualRange(return_address - image.load_bias - 16, 24) catch continue;
                        try stderr.print("  caller@0x{x} ({s}):", .{ return_address, node.path });
                        for (frame_code) |byte| try stderr.print(" {x:0>2}", .{byte});
                        try stderr.writeByte('\n');
                        var call_index: usize = 0;
                        while (call_index + 6 <= 16) : (call_index += 1) {
                            if (frame_code[call_index] != 0xff or frame_code[call_index + 1] != 0x15) continue;
                            const displacement = std.mem.readInt(i32, frame_code[call_index + 2 ..][0..4], .little);
                            const next_instruction = return_address - 16 + call_index + 6;
                            const target: u64 = @intCast(@as(i64, @intCast(next_instruction)) + displacement);
                            try reportRelocation(stderr, allocator, node, target);
                        }
                        break;
                    }
                }
            } else |_| {}
            try stderr.print(
                "  rax=0x{x} rbx=0x{x} rcx=0x{x} rdx=0x{x} rsi=0x{x} rdi=0x{x} rbp=0x{x}\n",
                .{
                    fault.info.registers.rax,
                    fault.info.registers.rbx,
                    fault.info.registers.rcx,
                    fault.info.registers.rdx,
                    fault.info.registers.rsi,
                    fault.info.registers.rdi,
                    fault.info.registers.rbp,
                },
            );
            const code_start = fault.info.instruction_address -| 16;
            var code: [32]u8 = undefined;
            if (emu.address_space.?.read(code_start, &code)) |_| {
                try stderr.print("  code@0x{x}:", .{code_start});
                for (code) |byte| try stderr.print(" {x:0>2}", .{byte});
                try stderr.writeByte('\n');
            } else |_| {
                for (graph.nodes.items) |*node| {
                    const image = &node.mapped.?;
                    if (code_start < image.load_bias) continue;
                    const bytes = node.image.virtualRange(code_start - image.load_bias, code.len) catch continue;
                    try stderr.print("  file-code@0x{x} ({s}):", .{ code_start, node.path });
                    for (bytes) |byte| try stderr.print(" {x:0>2}", .{byte});
                    try stderr.writeByte('\n');
                    var instruction: usize = 0;
                    while (instruction + 7 <= 16) : (instruction += 1) {
                        if (bytes[instruction] != 0x48 or bytes[instruction + 1] != 0x8b or bytes[instruction + 2] != 0x05) continue;
                        const displacement = std.mem.readInt(i32, bytes[instruction + 3 ..][0..4], .little);
                        const next_instruction = code_start + instruction + 7;
                        const target: u64 = @intCast(@as(i64, @intCast(next_instruction)) + displacement);
                        try reportRelocation(stderr, allocator, node, target);
                        break;
                    }
                    break;
                }
            }
        }
        try stderr.print("guest execution stopped: {s}\n", .{@errorName(err)});
        try stderr.flush();
        // Contained guest faults leave AGC/job workers in tight guest loops that
        // ignore interrupt flags (suspendPoint spam). Joining them in defer hangs
        // while burning every core. After the report is on the host terminal the
        // process has nothing left to do for this title run — exit immediately
        // so the OS reclaims the workers instead of waiting on them.
        std.process.exit(1);
    };

    if (runtime.firmware.trace.isLive()) {
        try stderr.writeAll("[trace] recent firmware calls before guest return:\n");
        try runtime.firmware.trace.write(stderr, runtime.firmware.trace.capacity);
        try stderr.flush();
    }

    const live_threads = emu.liveGuestThreadCount();
    var thread_info: [16]runtime.firmware.libs.kernel_threading.LiveThreadInfo = @splat(.{});
    const reported = @min(emu.liveGuestThreads(&thread_info), thread_info.len);
    var has_non_audio_thread = false;
    for (thread_info[0..reported]) |thread| {
        const name = std.mem.sliceTo(&thread.name, 0);
        if (!std.mem.startsWith(u8, name, "Audio")) has_non_audio_thread = true;
    }
    if (live_threads != 0) {
        try out.print(
            "guest bootstrap returned 0x{x}; {d} guest thread{s} still running\n",
            .{ result, live_threads, if (live_threads == 1) "" else "s" },
        );
        for (thread_info[0..reported]) |thread| {
            try out.print(
                "  live pthread 0x{x} {s}\n",
                .{ thread.entry_point, std.mem.sliceTo(&thread.name, 0) },
            );
        }
        try out.flush();
    }
    if (renderer_initialized and window_initialized and live_threads != 0 and has_non_audio_thread) {
        while (host_window.isOpen() and emu.liveGuestThreadCount() != 0) {
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }
    try out.print("guest process returned 0x{x}\n", .{result});
    try out.flush();
    return true;
}
