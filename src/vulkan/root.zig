// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Vulkan host renderer boundary.

pub const api = @import("api.zig");
pub const backend = @import("backend.zig");

pub const Error = backend.Error;
pub const Options = backend.Options;
pub const DeviceInfo = backend.DeviceInfo;
pub const SmokeReport = backend.SmokeReport;
pub const StagedBuffer = backend.StagedBuffer;
pub const DispatchReport = backend.DispatchReport;
pub const GuestMemory = backend.GuestMemory;
pub const NativeWindow = backend.NativeWindow;
pub const PresentedFrame = backend.PresentedFrame;
pub const PresentationSink = backend.PresentationSink;
pub const FrameRateSink = backend.FrameRateSink;
pub const FrameRateCounter = backend.FrameRateCounter;
pub const DisplayBuffer = backend.DisplayBuffer;
pub const DisplayBufferResolver = backend.DisplayBufferResolver;
pub const Renderer = backend.Renderer;
pub const graphics_probe_width = backend.graphics_probe_width;
pub const graphics_probe_height = backend.graphics_probe_height;

test {
    _ = api;
    _ = backend;
}
