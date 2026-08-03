// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! diag — making guest execution failures readable.
//!
//! Bringing a title up produces addresses, and an address on its own explains
//! nothing: it depends on where modules landed, and the most informative
//! failures are the ones whose faulting address belongs to no module at all.
//!
//! This layer attributes addresses to modules and exports, and turns a captured
//! fault into a statement about what the guest did.

pub const symbolize = @import("symbolize.zig");
pub const fault = @import("fault.zig");

pub const SymbolMap = symbolize.SymbolMap;
pub const Location = symbolize.Location;
pub const Diagnosis = fault.Diagnosis;
pub const FaultReport = fault.Report;

pub const analyzeFault = fault.analyze;
pub const writeFault = fault.write;
pub const writeStackTrace = fault.writeStackTrace;
pub const writeMessageArguments = fault.writeMessageArguments;
pub const readGuestText = fault.readGuestText;

test {
    _ = symbolize;
    _ = fault;
}
