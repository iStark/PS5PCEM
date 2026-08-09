// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! What the guest asks the graphics hardware to do.
//!
//! Kept apart from firmware emulation on purpose. A title reaches the GPU
//! through a command stream it builds itself, and that stream is the same
//! whichever layer hands it over — the graphics library, or the kernel device
//! the library's own driver submits through. Modelling it here means neither
//! choice of interception point is baked into the decoder.

const std = @import("std");

pub const pm4 = @import("pm4.zig");
pub const state = @import("state.zig");
pub const resources = @import("resources.zig");
pub const shaders = @import("shaders.zig");
pub const scalar_provenance = @import("scalar_provenance.zig");
pub const shader_analysis = @import("shader_analysis.zig");
pub const tiling = @import("tiling.zig");
pub const executor = @import("executor.zig");
pub const scheduler = @import("scheduler.zig");

pub const State = state.State;
pub const RenderState = resources.RenderState;
pub const BufferDescriptor = resources.BufferDescriptor;
pub const ImageDescriptor = resources.ImageDescriptor;
pub const SamplerDescriptor = resources.SamplerDescriptor;
pub const ShaderBindings = shaders.StageBindings;
pub const VertexShaderBindings = shaders.VertexBindings;
pub const VertexBindings = shaders.VertexBindings;
pub const VertexAttribute = shaders.VertexAttribute;
pub const ShaderMemoryReader = shaders.MemoryReader;
pub const ScalarEvaluation = scalar_provenance.Evaluation;
pub const ShaderAnalysis = shader_analysis.Analysis;
pub const ShaderSpirvStage = shader_analysis.SpirvStage;
pub const ShaderSpirvStorageBufferBinding = shader_analysis.SpirvStorageBufferBinding;
pub const ShaderSpirvSampledImageBinding = shader_analysis.SpirvSampledImageBinding;
pub const ShaderSpirvScalarRegister = shader_analysis.SpirvScalarRegister;
pub const ShaderOperand = shader_analysis.Operand;
pub const ShaderOperandKind = shader_analysis.OperandKind;
pub const ShaderInstruction = shader_analysis.Instruction;
pub const ShaderOpcode = shader_analysis.Opcode;
pub const SurfaceLayout = tiling.Layout;
pub const MetadataSurface = tiling.MetadataSurface;
pub const TextureLayout = tiling.TextureLayout;
pub const TextureSubresourceLayout = tiling.SubresourceLayout;
pub const ComputeDetileKey = tiling.ComputeDetileKey;
pub const ComputeDetileParams = tiling.ComputeDetileParams;
pub const ComputeDetilePlan = tiling.ComputeDetilePlan;
pub const BufferStagingLayout = tiling.BufferLayout;
pub const DcbExecutor = executor.DcbExecutor;
pub const DcbBackend = executor.Backend;
pub const DcbContinuation = executor.Continuation;
pub const QueueScheduler = scheduler.Scheduler;
pub const QueueKind = scheduler.QueueKind;

test {
    std.testing.refAllDecls(@This());
    _ = pm4;
    _ = state;
    _ = resources;
    _ = shaders;
    _ = scalar_provenance;
    _ = shader_analysis;
    _ = tiling;
    _ = executor;
    _ = scheduler;
}
