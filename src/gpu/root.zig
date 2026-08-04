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
pub const executor = @import("executor.zig");

pub const State = state.State;
pub const DcbExecutor = executor.DcbExecutor;
pub const DcbBackend = executor.Backend;
pub const DcbContinuation = executor.Continuation;

test {
    std.testing.refAllDecls(@This());
    _ = pm4;
    _ = state;
    _ = executor;
}
