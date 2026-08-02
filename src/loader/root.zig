//! loader — reading guest module images.
//!
//! Parses the ELF64 objects a title ships and the dynamic linking tables inside
//! them, producing a description of what a module provides and what it needs.
//!
//! Nothing here maps or executes anything: this layer answers what is in the
//! file, not where it goes in memory. Placing segments needs a guest address
//! space, and resolving imports needs the firmware registry — both belong to
//! callers of this module.

pub const elf = @import("elf.zig");
pub const dynamic = @import("dynamic.zig");
pub const ids = @import("ids.zig");

pub const Image = elf.Image;
pub const ObjectType = elf.ObjectType;
pub const SegmentType = elf.SegmentType;
pub const ProgramHeader = elf.ProgramHeader;
pub const DynamicInfo = dynamic.DynamicInfo;
pub const LibraryDecl = dynamic.LibraryDecl;
pub const ModuleDecl = dynamic.ModuleDecl;
pub const SymbolName = dynamic.SymbolName;

pub const parseImage = elf.parse;
pub const parseDynamic = dynamic.parse;
pub const parseSymbolName = dynamic.parseSymbolName;

test {
    _ = elf;
    _ = dynamic;
    _ = ids;
}
