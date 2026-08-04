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
pub const Renderer = backend.Renderer;

test {
    _ = api;
    _ = backend;
}
