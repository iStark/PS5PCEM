// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Loads, initializes, and enters a decrypted PS5 title through the native
//! Windows x86-64 guest bridge.

const std = @import("std");
const runtime = @import("runtime");
const loader = @import("loader");

const usage =
    \\game-run <eboot.bin>
    \\
    \\Loads and relocates the adjacent PRX graph, runs its initializers, then
    \\enters the title process. Direct execution requires Windows x86-64.
    \\
;

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
    const allocator = init.arena.allocator();

    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return false;
    }

    var emu = runtime.Runtime{};
    try emu.init(allocator);
    defer emu.deinit();

    var graph = emu.loadModuleGraph(io, args[1], .{}) catch |err| {
        try stderr.print("cannot link {s}: {s}\n", .{ args[1], @errorName(err) });
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
    const loaded_modules = try graph.publishModules(allocator);
    defer {
        runtime.firmware.modules.detach();
        allocator.free(loaded_modules);
    }

    // The directory holding the executable is what a title sees as /app0.
    const title_root = std.fs.path.dirname(args[1]) orelse ".";
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
    if (init.minimal.environ.containsUnempty(allocator, "PS5_TRACE") catch false) {
        runtime.firmware.trace.setLive(true);
    }

    try emu.enableNativeCpuDispatcher(io);
    const prepared = try emu.prepareInitialThread("eboot-main");
    defer emu.releaseInitialThread(prepared.handle) catch {};

    try out.print("loaded {s}\n", .{args[1]});
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
            .entry = .{ .image_name = std.fs.path.basename(args[1]) },
            .modules = graph.modules(),
        },
    ) catch |err| {
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
        return false;
    };

    try out.print("guest process returned 0x{x}\n", .{result});
    try out.flush();
    return true;
}
