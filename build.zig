// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        },
    });

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

    const test_step = b.step("test", "Run the test suite");
    const check_step = b.step("check", "Compile every module without running tests");
    for ([_]*std.Build.Module{
        memory,
        mod,
        hle,
        cpu,
        loader,
        runtime,
        exe.root_module,
        module_info.root_module,
        graph_info.root_module,
    }) |m| {
        const tests = b.addTest(.{ .root_module = m });
        check_step.dependOn(&tests.step);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
