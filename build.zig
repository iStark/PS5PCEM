// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // An emulator interprets guest instructions, translates guest shaders and
    // converts guest pixels, and it does all of that per frame. An unoptimized
    // build of that work is not a slower version of the same program, it is a
    // program that cannot keep up: a movie frame costs six times more to
    // convert under `Debug` than under a release mode, which is the difference
    // between playing an intro and waiting through it. Safety is kept, because
    // everything here decodes data the emulator did not produce and a checked
    // failure says far more than undefined behaviour; `-Doptimize=Debug` is
    // still one flag away when a debugger needs it.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;
    const libatrac9 = b.dependency("libatrac9", .{});
    const minimp3 = b.dependency("minimp3", .{});
    const faad2 = b.dependency("faad2", .{});
    const libopus = b.dependency("libopus", .{});

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
    hle.addIncludePath(faad2.path("include"));
    hle.addIncludePath(b.path("src/hle/codecs"));
    hle.addIncludePath(libopus.path("include"));

    const faad_lib = b.addLibrary(.{
        .name = "faad2",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    faad_lib.root_module.addIncludePath(faad2.path("include"));
    faad_lib.root_module.addIncludePath(faad2.path("libfaad"));
    faad_lib.root_module.addCSourceFiles(.{
        .root = faad2.path("libfaad"),
        .files = &.{
            "bits.c",
            "cfft.c",
            "common.c",
            "decoder.c",
            "drc.c",
            "drm_dec.c",
            "error.c",
            "filtbank.c",
            "hcr.c",
            "huffman.c",
            "ic_predict.c",
            "is.c",
            "lt_predict.c",
            "mdct.c",
            "mp4.c",
            "ms.c",
            "output.c",
            "pns.c",
            "ps_dec.c",
            "ps_syntax.c",
            "pulse.c",
            "rvlc.c",
            "sbr_dct.c",
            "sbr_dec.c",
            "sbr_e_nf.c",
            "sbr_fbt.c",
            "sbr_hfadj.c",
            "sbr_hfgen.c",
            "sbr_huff.c",
            "sbr_qmf.c",
            "sbr_syntax.c",
            "sbr_tf_grid.c",
            "specrec.c",
            "ssr.c",
            "ssr_fb.c",
            "ssr_ipqf.c",
            "syntax.c",
            "tns.c",
        },
        .flags = &.{
            "-std=c99",
            "-O2",
            "-DHAVE_STDINT_H=1",
            "-DHAVE_STDLIB_H=1",
            "-DHAVE_STRING_H=1",
            "-DHAVE_MEMCPY=1",
            "-DFAAD2_VERSION=\"2.11.2\"",
            "-DPACKAGE_VERSION=\"2.11.2\"",
        },
    });
    hle.linkLibrary(faad_lib);

    const opus_lib = b.addLibrary(.{
        .name = "opus",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    opus_lib.root_module.addIncludePath(libopus.path("include"));
    opus_lib.root_module.addIncludePath(libopus.path("celt"));
    opus_lib.root_module.addIncludePath(libopus.path("silk"));
    opus_lib.root_module.addIncludePath(libopus.path("silk/float"));
    opus_lib.root_module.addIncludePath(libopus.path("src"));
    opus_lib.root_module.addCSourceFiles(.{
        .root = libopus.path("."),
        .files = &.{
            "celt/bands.c",
            "celt/celt.c",
            "celt/celt_decoder.c",
            "celt/celt_encoder.c",
            "celt/celt_lpc.c",
            "celt/cwrs.c",
            "celt/entcode.c",
            "celt/entdec.c",
            "celt/entenc.c",
            "celt/kiss_fft.c",
            "celt/laplace.c",
            "celt/mathops.c",
            "celt/mdct.c",
            "celt/modes.c",
            "celt/pitch.c",
            "celt/quant_bands.c",
            "celt/rate.c",
            "celt/vq.c",
            "silk/A2NLSF.c",
            "silk/CNG.c",
            "silk/HP_variable_cutoff.c",
            "silk/LPC_analysis_filter.c",
            "silk/LPC_fit.c",
            "silk/LPC_inv_pred_gain.c",
            "silk/LP_variable_cutoff.c",
            "silk/NLSF2A.c",
            "silk/NLSF_VQ.c",
            "silk/NLSF_VQ_weights_laroia.c",
            "silk/NLSF_decode.c",
            "silk/NLSF_del_dec_quant.c",
            "silk/NLSF_encode.c",
            "silk/NLSF_stabilize.c",
            "silk/NLSF_unpack.c",
            "silk/NSQ.c",
            "silk/NSQ_del_dec.c",
            "silk/PLC.c",
            "silk/VAD.c",
            "silk/VQ_WMat_EC.c",
            "silk/ana_filt_bank_1.c",
            "silk/biquad_alt.c",
            "silk/bwexpander.c",
            "silk/bwexpander_32.c",
            "silk/check_control_input.c",
            "silk/code_signs.c",
            "silk/control_SNR.c",
            "silk/control_audio_bandwidth.c",
            "silk/control_codec.c",
            "silk/debug.c",
            "silk/dec_API.c",
            "silk/decode_core.c",
            "silk/decode_frame.c",
            "silk/decode_indices.c",
            "silk/decode_parameters.c",
            "silk/decode_pitch.c",
            "silk/decode_pulses.c",
            "silk/decoder_set_fs.c",
            "silk/enc_API.c",
            "silk/encode_indices.c",
            "silk/encode_pulses.c",
            "silk/gain_quant.c",
            "silk/init_decoder.c",
            "silk/init_encoder.c",
            "silk/inner_prod_aligned.c",
            "silk/interpolate.c",
            "silk/lin2log.c",
            "silk/log2lin.c",
            "silk/pitch_est_tables.c",
            "silk/process_NLSFs.c",
            "silk/quant_LTP_gains.c",
            "silk/resampler.c",
            "silk/resampler_down2.c",
            "silk/resampler_down2_3.c",
            "silk/resampler_private_AR2.c",
            "silk/resampler_private_IIR_FIR.c",
            "silk/resampler_private_down_FIR.c",
            "silk/resampler_private_up2_HQ.c",
            "silk/resampler_rom.c",
            "silk/shell_coder.c",
            "silk/sigm_Q15.c",
            "silk/sort.c",
            "silk/stereo_LR_to_MS.c",
            "silk/stereo_MS_to_LR.c",
            "silk/stereo_decode_pred.c",
            "silk/stereo_encode_pred.c",
            "silk/stereo_find_predictor.c",
            "silk/stereo_quant_pred.c",
            "silk/sum_sqr_shift.c",
            "silk/table_LSF_cos.c",
            "silk/tables_LTP.c",
            "silk/tables_NLSF_CB_NB_MB.c",
            "silk/tables_NLSF_CB_WB.c",
            "silk/tables_gain.c",
            "silk/tables_other.c",
            "silk/tables_pitch_lag.c",
            "silk/tables_pulses_per_block.c",
            "silk/float/LPC_analysis_filter_FLP.c",
            "silk/float/LPC_inv_pred_gain_FLP.c",
            "silk/float/LTP_analysis_filter_FLP.c",
            "silk/float/LTP_scale_ctrl_FLP.c",
            "silk/float/apply_sine_window_FLP.c",
            "silk/float/autocorrelation_FLP.c",
            "silk/float/burg_modified_FLP.c",
            "silk/float/bwexpander_FLP.c",
            "silk/float/corrMatrix_FLP.c",
            "silk/float/encode_frame_FLP.c",
            "silk/float/energy_FLP.c",
            "silk/float/find_LPC_FLP.c",
            "silk/float/find_LTP_FLP.c",
            "silk/float/find_pitch_lags_FLP.c",
            "silk/float/find_pred_coefs_FLP.c",
            "silk/float/inner_product_FLP.c",
            "silk/float/k2a_FLP.c",
            "silk/float/noise_shape_analysis_FLP.c",
            "silk/float/pitch_analysis_core_FLP.c",
            "silk/float/process_gains_FLP.c",
            "silk/float/regularize_correlations_FLP.c",
            "silk/float/residual_energy_FLP.c",
            "silk/float/scale_copy_vector_FLP.c",
            "silk/float/scale_vector_FLP.c",
            "silk/float/schur_FLP.c",
            "silk/float/sort_FLP.c",
            "silk/float/warped_autocorrelation_FLP.c",
            "silk/float/wrappers_FLP.c",
            "src/extensions.c",
            "src/opus.c",
            "src/opus_decoder.c",
            "src/opus_multistream.c",
            "src/opus_multistream_decoder.c",
            "src/repacketizer.c",
        },
        .flags = &.{
            "-std=c99",
            "-O2",
            "-DOPUS_BUILD=1",
            "-DUSE_ALLOCA=1",
            "-DHAVE_LRINT=1",
            "-DHAVE_LRINTF=1",
            "-DHAVE_STDINT_H=1",
            "-DVAR_ARRAYS=1",
            "-DFLOATING_POINT=1",
            "-DPACKAGE_VERSION=\"1.5.2\"",
        },
    });
    hle.linkLibrary(opus_lib);

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
        const install_native_launcher = b.addInstallArtifact(native_launcher, .{});
        b.getInstallStep().dependOn(&install_native_launcher.step);

        const build_launcher_step = b.step("build-launcher", "Build only the native PS5PCEM launcher");
        build_launcher_step.dependOn(&install_native_launcher.step);

        // Run the installed copy: it resolves game-run.exe beside itself. The
        // old addRunArtifact path executed from Zig's cache and depended on the
        // entire install graph, rebuilding unrelated inspection tools.
        const launcher_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "ps5pcem.exe")});
        launcher_cmd.step.dependOn(&install_native_launcher.step);
        launcher_cmd.step.dependOn(&install_game_run.step);
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
