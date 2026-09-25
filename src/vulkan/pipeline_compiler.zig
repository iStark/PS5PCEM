// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Compilation uses the common CPU queue, preserving foreground priority.
pub const Job = @import("gpu").cpu_workers.Job;
pub const Queue = @import("gpu").cpu_workers.Queue;
