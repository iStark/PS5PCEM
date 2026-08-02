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

    const test_step = b.step("test", "Run the test suite");
    for ([_]*std.Build.Module{ mod, hle, exe.root_module }) |m| {
        const tests = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
