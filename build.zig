// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libatrac9 = b.dependency("libatrac9", .{});
    const minimp3 = b.dependency("minimp3", .{});

    // Fixed-address guest virtual memory. Kept below loader and HLE so both can
    // use the same identity-mapped address space without depending on each
    // other.
    const memory = b.addModule("memory", .{
        .root_source_file = b.path("src/memory/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The shader decoder. Kept separate from the CLI so it can be consumed as
    // a module, or later built as a static library with a C ABI.
    const mod = b.addModule("rdna2", .{
        .root_source_file = b.path("src/rdna2/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The GPU command stream and draw-boundary shader state. Shader scalar
    // provenance reuses the standalone RDNA2 decoder without coupling it to HLE.
    const gpu = b.addModule("gpu", .{
        .root_source_file = b.path("src/gpu/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rdna2", .module = mod },
        },
    });

    // Host renderer foundation. Vulkan is loaded dynamically at runtime, so
    // compiling the emulator does not require SDK headers or loader libraries.
    const vulkan = b.addModule("vulkan", .{
        .root_source_file = b.path("src/vulkan/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gpu", .module = gpu },
            .{ .name = "rdna2", .module = mod },
        },
    });

    // Native host-window ownership. Kept separate from Vulkan so the renderer
    // continues to support headless diagnostics and non-Windows builds.
    const window = b.addModule("window", .{
        .root_source_file = b.path("src/window/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Host keyboard and XInput polling. Kept out of libScePad so the guest ABI
    // remains independent from the launcher and Windows message handling.
    const input = b.addModule("input", .{
        .root_source_file = b.path("src/input/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Guest module images: ELF64 parsing and the dynamic linking tables.
    const loader = b.addModule("loader", .{
        .root_source_file = b.path("src/loader/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memory", .module = memory },
        },
    });

    // Firmware emulation: identifier derivation, the symbol registry, and the
    // guest-facing libraries. Thread bootstrap consumes immutable TLS
    // templates from the loader without introducing a dependency back into it.
    const hle = b.addModule("hle", .{
        .root_source_file = b.path("src/hle/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memory", .module = memory },
            .{ .name = "loader", .module = loader },
            .{ .name = "gpu", .module = gpu },
            .{ .name = "input", .module = input },
        },
    });
    hle.addIncludePath(libatrac9.path("C/src"));
    hle.addIncludePath(minimp3.path("."));
    hle.addCSourceFiles(.{
        .root = libatrac9.path("C/src"),
        .files = &.{
            "band_extension.c",
            "bit_allocation.c",
            "bit_reader.c",
            "decinit.c",
            "decoder.c",
            "huffCodes.c",
            "imdct.c",
            "libatrac9.c",
            "quantization.c",
            "scale_factors.c",
            "tables.c",
            "unpack.c",
        },
        .flags = &.{ "-std=c99", "-O2" },
    });
    hle.addCSourceFiles(.{
        .files = &.{
            "src/hle/codecs/libatrac9_utility.c",
            "src/hle/codecs/minimp3_impl.c",
        },
        .flags = &.{ "-std=c99", "-O2" },
    });
    hle.link_libc = true;

    // Guest CPU dispatch: host worker lifecycle and scheduler semantics stay
    // separate from the platform-specific machine execution bridge.
    const cpu = b.addModule("cpu", .{
        .root_source_file = b.path("src/cpu/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memory", .module = memory },
            .{ .name = "loader", .module = loader },
            .{ .name = "hle", .module = hle },
        },
    });

    // Failure attribution: guest addresses back to modules and exports, and
    // captured faults into readable reports. Depends on cpu only for the fault
    // record layout, so nothing in the execution path depends on diagnostics.
    const diag = b.addModule("diag", .{
        .root_source_file = b.path("src/diag/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memory", .module = memory },
            .{ .name = "loader", .module = loader },
            .{ .name = "cpu", .module = cpu },
        },
    });

    // End-to-end composition: address space, ELF loader, HLE export database,
    // and optional CPU dispatch wired together by one process runtime.
    const runtime = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memory", .module = memory },
            .{ .name = "loader", .module = loader },
            .{ .name = "hle", .module = hle },
            .{ .name = "cpu", .module = cpu },
            .{ .name = "diag", .module = diag },
        },
    });

    const exe = b.addExecutable(.{
        .name = "rdna2-disasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rdna2", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the disassembler");
    run_step.dependOn(&run_cmd.step);

    // Inspects a guest module and reports which of its imports the firmware
    // emulation can supply.
    const module_info = b.addExecutable(.{
        .name = "module-info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/module_info.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "loader", .module = loader },
                .{ .name = "hle", .module = hle },
            },
        }),
    });
    b.installArtifact(module_info);

    const module_info_cmd = b.addRunArtifact(module_info);
    module_info_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| module_info_cmd.addArgs(args);

    const module_info_step = b.step("module-info", "Inspect a guest module");
    module_info_step.dependOn(&module_info_cmd.step);

    // Decodes a captured GPU command stream.
    const pm4_dump = b.addExecutable(.{
        .name = "pm4-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pm4_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gpu", .module = gpu }},
        }),
    });
    b.installArtifact(pm4_dump);

    const pm4_dump_cmd = b.addRunArtifact(pm4_dump);
    pm4_dump_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| pm4_dump_cmd.addArgs(args);

    const pm4_dump_step = b.step("pm4-dump", "Decode a captured GPU command stream");
    pm4_dump_step.dependOn(&pm4_dump_cmd.step);

    // Verifies that a real executable/PRX dependency graph can be mapped and
    // relocated without entering guest code.
    const graph_info = b.addExecutable(.{
        .name = "graph-info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/graph_info.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime", .module = runtime }},
        }),
    });
    b.installArtifact(graph_info);

    const graph_info_cmd = b.addRunArtifact(graph_info);
    graph_info_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| graph_info_cmd.addArgs(args);

    const graph_info_step = b.step("graph-info", "Map and relocate a guest module graph");
    graph_info_step.dependOn(&graph_info_cmd.step);

    // Loads the title graph and enters the process through the native Windows
    // x86-64 guest bridge.
    const game_run = b.addExecutable(.{
        .name = "game-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/game_run.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime },
                .{ .name = "loader", .module = loader },
                .{ .name = "gpu", .module = gpu },
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "window", .module = window },
            },
        }),
    });
    if (target.result.os.tag == .windows) {
        // Native guest code requires the complete 64 GiB..1008 GiB PS5 user
        // window. High-entropy ASLR occasionally placed game-run itself in
        // that range and split it so Unreal could not reserve its 512 GiB
        // arena. Keep the host image at 2 TiB, outside every guest aperture.
        game_run.image_base = 0x0200_0000_0000;
        game_run.root_module.linkSystemLibrary("xinput1_4", .{});
        // Sony pads are read straight from HID; XInput never enumerates them.
        game_run.root_module.linkSystemLibrary("setupapi", .{});
        game_run.root_module.linkSystemLibrary("hid", .{});
    }
    const install_game_run = b.addInstallArtifact(game_run, .{});
    b.getInstallStep().dependOn(&install_game_run.step);

    const build_game_run_step = b.step("build-game-run", "Build only the PS5 title runner");
    build_game_run_step.dependOn(&install_game_run.step);

    const game_run_cmd = b.addRunArtifact(game_run);
    game_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| game_run_cmd.addArgs(args);

    const game_run_step = b.step("game-run", "Load and execute a decrypted PS5 title");
    game_run_step.dependOn(&game_run_cmd.step);

    // Zero-dependency native launcher. It selects the title directory, stores
    // user preferences and starts game-run with the corresponding environment.
    var launcher: ?*std.Build.Step.Compile = null;
    if (target.result.os.tag == .windows) {
        const native_launcher = b.addExecutable(.{
            .name = "ps5pcem",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/launcher.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "input", .module = input }},
            }),
        });
        native_launcher.subsystem = .windows;
        inline for (&.{ "user32", "gdi32", "shell32", "ole32", "dwmapi", "setupapi", "hid" }) |library| {
            native_launcher.root_module.linkSystemLibrary(library, .{});
        }
        b.installArtifact(native_launcher);

        const launcher_cmd = b.addRunArtifact(native_launcher);
        launcher_cmd.step.dependOn(b.getInstallStep());
        const launcher_step = b.step("launcher", "Open the PS5PCEM launcher");
        launcher_step.dependOn(&launcher_cmd.step);
        launcher = native_launcher;
    }

    // Verifies device/queue creation, a compute pipeline and synchronized
    // staging through device-local memory without opening a window.
    const vulkan_smoke = b.addExecutable(.{
        .name = "vulkan-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "gpu", .module = gpu },
            },
        }),
    });
    b.installArtifact(vulkan_smoke);

    const vulkan_smoke_cmd = b.addRunArtifact(vulkan_smoke);
    vulkan_smoke_cmd.step.dependOn(b.getInstallStep());
    const vulkan_smoke_step = b.step("vulkan-smoke", "Run the headless Vulkan compute/staging probe");
    vulkan_smoke_step.dependOn(&vulkan_smoke_cmd.step);

    // Opens a real Win32 surface, uploads a diagnostic frame to a swapchain
    // image and presents it through the same sink used by live VideoOut flips.
    const vulkan_window_smoke = b.addExecutable(.{
        .name = "vulkan-window-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan_window_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "gpu", .module = gpu },
                .{ .name = "window", .module = window },
            },
        }),
    });
    b.installArtifact(vulkan_window_smoke);

    const vulkan_window_smoke_cmd = b.addRunArtifact(vulkan_window_smoke);
    vulkan_window_smoke_cmd.step.dependOn(b.getInstallStep());
    const vulkan_window_smoke_step = b.step("vulkan-window-smoke", "Present a diagnostic frame to a Win32 Vulkan window");
    vulkan_window_smoke_step.dependOn(&vulkan_window_smoke_cmd.step);

    const test_step = b.step("test", "Run the test suite");
    const check_step = b.step("check", "Compile every module without running tests");
    check_step.dependOn(&vulkan_smoke.step);
    if (launcher) |native_launcher| check_step.dependOn(&native_launcher.step);
    for ([_]*std.Build.Module{
        memory,
        mod,
        gpu,
        vulkan,
        window,
        input,
        hle,
        cpu,
        loader,
        diag,
        runtime,
        exe.root_module,
        module_info.root_module,
        pm4_dump.root_module,
        graph_info.root_module,
        game_run.root_module,
        vulkan_smoke.root_module,
        vulkan_window_smoke.root_module,
    }) |m| {
        const tests = b.addTest(.{ .root_module = m });
        check_step.dependOn(&tests.step);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
