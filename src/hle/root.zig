// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! hle — high-level emulation of the guest firmware.
//!
//! Guest binaries do not carry the firmware they call into; they import it by
//! numeric identifier and expect the runtime to supply implementations. This
//! module provides that machinery — identifier derivation, the symbol registry
//! the dynamic linker resolves against, the calling-convention boundary — and
//! the firmware libraries built on top of it.

pub const nid = @import("nid.zig");
pub const abi = @import("abi.zig");
pub const trace = @import("trace.zig");
pub const unwind = @import("unwind.zig");
pub const modules = @import("modules.zig");
pub const filesystem = @import("filesystem.zig");
pub const host_stack = @import("host_stack.zig");
pub const video_out = @import("video_out.zig");
pub const errno = @import("errno.zig");
pub const symbols = @import("symbols.zig");

pub const libs = struct {
    pub const audio = @import("libs/audio.zig");
    pub const bootstrap_services = @import("libs/bootstrap_services.zig");
    pub const dialogs = @import("libs/dialogs.zig");
    pub const kernel_event_queue = @import("libs/kernel_event_queue.zig");
    pub const kernel_info = @import("libs/kernel_info.zig");
    pub const kernel_ioctl = @import("libs/kernel_ioctl.zig");
    pub const agc = @import("libs/agc.zig");
    pub const agc_submit = @import("libs/agc_submit.zig");
    pub const kernel_aio = @import("libs/kernel_aio.zig");
    pub const kernel_files = @import("libs/kernel_files.zig");
    pub const kernel_memory = @import("libs/kernel_memory.zig");
    pub const kernel_runtime = @import("libs/kernel_runtime.zig");
    pub const kernel_sync = @import("libs/kernel_sync.zig");
    pub const kernel_threading = @import("libs/kernel_threading.zig");
    pub const libc_internal = @import("libs/libc_internal.zig");
    pub const network = @import("libs/network.zig");
    pub const platform_services = @import("libs/platform_services.zig");
    pub const registry = @import("libs/registry.zig");
    pub const services = @import("libs/services.zig");
    pub const pad = @import("libs/pad.zig");
    pub const sysmodule = @import("libs/sysmodule.zig");
    pub const system_service = @import("libs/system_service.zig");
    pub const user_service = @import("libs/user_service.zig");
};

pub const Database = symbols.Database;
pub const Export = symbols.Export;
pub const Library = symbols.Library;
pub const Module = symbols.Module;
pub const SymbolType = symbols.SymbolType;
pub const KernelError = errno.KernelError;

/// Every firmware library the runtime provides.
///
/// Registration is explicit rather than automatic: the list is what the guest
/// can see, so it should be readable in one place.
pub fn registerAll(db: *Database, gpa: @import("std").mem.Allocator) symbols.Error!void {
    try libs.audio.register(db, gpa);
    try libs.agc.register(db, gpa);
    try libs.kernel_aio.register(db, gpa);
    try libs.bootstrap_services.register(db, gpa);
    try libs.dialogs.register(db, gpa);
    try libs.kernel_event_queue.register(db, gpa);
    try libs.kernel_files.register(db, gpa);
    try libs.kernel_info.register(db, gpa);
    try libs.kernel_ioctl.register(db, gpa);
    try libs.kernel_memory.register(db, gpa);
    try libs.kernel_runtime.register(db, gpa);
    try libs.kernel_sync.register(db, gpa);
    try libs.kernel_threading.register(db, gpa);
    try libs.libc_internal.register(db, gpa);
    try libs.network.register(db, gpa);
    try libs.platform_services.register(db, gpa);
    try libs.registry.register(db, gpa);
    try libs.services.register(db, gpa);
    try libs.pad.register(db, gpa);
    try libs.sysmodule.register(db, gpa);
    try libs.system_service.register(db, gpa);
    try libs.user_service.register(db, gpa);
}

test {
    _ = libs.audio;
    _ = libs.bootstrap_services;
    _ = libs.dialogs;
    _ = nid;
    _ = abi;
    _ = trace;
    _ = unwind;
    _ = modules;
    _ = filesystem;
    _ = host_stack;
    _ = video_out;
    _ = errno;
    _ = symbols;
    _ = libs.kernel_event_queue;
    _ = libs.kernel_info;
    _ = libs.kernel_ioctl;
    _ = libs.agc;
    _ = libs.agc_submit;
    _ = libs.kernel_aio;
    _ = libs.kernel_files;
    _ = libs.kernel_memory;
    _ = libs.kernel_runtime;
    _ = libs.kernel_sync;
    _ = libs.kernel_threading;
    _ = libs.libc_internal;
    _ = libs.network;
    _ = libs.platform_services;
    _ = libs.registry;
    _ = libs.services;
    _ = libs.pad;
    _ = libs.sysmodule;
    _ = libs.system_service;
    _ = libs.user_service;
}
