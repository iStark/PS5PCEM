// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The shader decoder. Kept separate from the CLI so it can be consumed as
    // a module, or later built as a static library with a C ABI.
    const mod = b.addModule("rdna2", .{
        .root_source_file = b.path("src/rdna2/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Firmware emulation: identifier derivation, the symbol registry, and the
    // guest-facing libraries. Independent of the shader decoder.
    const hle = b.addModule("hle", .{
        .root_source_file = b.path("src/hle/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Guest module images: ELF64 parsing and the dynamic linking tables.
    const loader = b.addModule("loader", .{
        .root_source_file = b.path("src/loader/root.zig"),
        .target = target,
        .optimize = optimize,
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

    const test_step = b.step("test", "Run the test suite");
    for ([_]*std.Build.Module{ mod, hle, loader, exe.root_module, module_info.root_module }) |m| {
        const tests = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
