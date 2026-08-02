// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! loader — reading guest ELF and decrypted PS5 SELF module images.
//!
//! Parses the ELF64 objects a title ships and the dynamic linking tables inside
//! them, producing a description of what a module provides and what it needs.
//! Parsed images can then be placed at exact guest addresses and relocated
//! through a caller-supplied symbol resolver.

pub const elf = @import("elf.zig");
pub const self = @import("self.zig");
pub const dynamic = @import("dynamic.zig");
pub const ids = @import("ids.zig");
pub const symbols = @import("symbols.zig");
pub const relocations = @import("relocations.zig");
pub const imports = @import("imports.zig");
pub const linker = @import("linker.zig");
pub const image_loader = @import("image_loader.zig");
pub const tls = @import("tls.zig");
pub const exports = @import("exports.zig");

pub const Image = elf.Image;
pub const ObjectType = elf.ObjectType;
pub const SegmentType = elf.SegmentType;
pub const ProgramHeader = elf.ProgramHeader;
pub const DynamicInfo = dynamic.DynamicInfo;
pub const LibraryDecl = dynamic.LibraryDecl;
pub const ModuleDecl = dynamic.ModuleDecl;
pub const SymbolName = dynamic.SymbolName;
pub const Import = imports.Import;
pub const Imports = imports.Imports;
pub const Resolver = linker.Resolver;
pub const RelocationStats = linker.Stats;
pub const TlsRegistry = tls.Registry;
pub const TlsModule = tls.Module;
pub const TlsResolvedSymbol = tls.ResolvedSymbol;
pub const GuestExportRegistry = exports.Registry;
pub const GuestExportModule = exports.Module;
pub const GuestExport = exports.Export;
pub const LoadOptions = image_loader.Options;
pub const MappedImage = image_loader.MappedImage;
pub const PreparedImage = image_loader.PreparedImage;

pub const parseImage = elf.parse;
pub const parseDynamic = dynamic.parse;
pub const parseSymbolName = dynamic.parseSymbolName;
pub const collectImports = imports.collect;
pub const collectGuestExports = exports.collect;
pub const applyRelocations = linker.apply;
pub const loadImage = image_loader.load;
pub const prepareImage = image_loader.prepare;
pub const linkImage = image_loader.link;

test {
    _ = elf;
    _ = self;
    _ = dynamic;
    _ = ids;
    _ = symbols;
    _ = relocations;
    _ = imports;
    _ = linker;
    _ = image_loader;
    _ = tls;
    _ = exports;
}
