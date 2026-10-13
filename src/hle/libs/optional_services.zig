// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Explicit unavailable-service bindings. These do not manufacture handles,
//! successful network sessions, rendered audio paths or exported captures.
const services = @import("services.zig");
const share = @import("share.zig");
const propagation = @import("audio_propagation.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");

const libSceRudp_exports = [_]symbols.Export{
    .{ .name = "sceRudpCreateContext", .function = trace.wrap("sceRudpCreateContext", &services.offline), .expect_id = "CAbbX6BuQZ0" },
    .{ .name = "sceRudpTerminate", .function = trace.wrap("sceRudpTerminate", &services.offline), .expect_id = "OMYRTU0uc4w" },
    .{ .name = "sceRudpWrite", .function = trace.wrap("sceRudpWrite", &services.offline), .expect_id = "KaPL3fbTLCA" },
    .{ .name = "sceRudpInitiate", .function = trace.wrap("sceRudpInitiate", &services.offline), .expect_id = "szEVu+edXV4" },
    .{ .name = "sceRudpBind", .function = trace.wrap("sceRudpBind", &services.offline), .expect_id = "l4SLBpKUDK4" },
    .{ .name = "sceRudpSetOption", .function = trace.wrap("sceRudpSetOption", &services.offline), .expect_id = "0yzYdZf0IwE" },
    .{ .name = "sceRudpSetEventHandler", .function = trace.wrap("sceRudpSetEventHandler", &services.offline), .expect_id = "SUEVes8gvmw" },
    .{ .name = "sceRudpGetContextStatus", .function = trace.wrap("sceRudpGetContextStatus", &services.offline), .expect_id = "wIJsiqY+BMk" },
    .{ .name = "sceRudpEnd", .function = trace.wrap("sceRudpEnd", &services.offline), .expect_id = "3hBvwqEwqj8" },
    .{ .name = "sceRudpRead", .function = trace.wrap("sceRudpRead", &services.offline), .expect_id = "rZqWV3eXgOA" },
    .{ .name = "sceRudpEnableInternalIOThread", .function = trace.wrap("sceRudpEnableInternalIOThread", &services.offline), .expect_id = "6PBNpsgyaxw" },
    .{ .name = "sceRudpInit", .function = trace.wrap("sceRudpInit", &services.offline), .expect_id = "amuBfI-AQc4" },
};

const libSceVoiceChat_exports = [_]symbols.Export{
    .{ .name = "sceVoiceChatRequestCreateGameSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestCreateGameSessionVoiceChatChannel", &services.offline), .expect_id = "y7MgGX889Mo" },
    .{ .name = "sceVoiceChatRequestRegisterSession", .function = trace.wrap("sceVoiceChatRequestRegisterSession", &services.offline), .expect_id = "po9eImAEhY4" },
    .{ .name = "sceVoiceChatRequestDeleteGameSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestDeleteGameSessionVoiceChatChannel", &services.offline), .expect_id = "7bu++dneYUU" },
    .{ .name = "sceVoiceChatDeleteRequest", .function = trace.wrap("sceVoiceChatDeleteRequest", &services.offline), .expect_id = "eEMpsX1fGHU" },
    .{ .name = "sceVoiceChatRequestDeletePlayerSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestDeletePlayerSessionVoiceChatChannel", &services.offline), .expect_id = "zbKF-ejbR0Q" },
    .{ .name = "sceVoiceChatRegisterMicEventHandler", .function = trace.wrap("sceVoiceChatRegisterMicEventHandler", &services.offline), .expect_id = "ajXKK3BOVc8" },
    .{ .name = "sceVoiceChatRequestLeavePlayerSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestLeavePlayerSessionVoiceChatChannel", &services.offline), .expect_id = "0rKMjtnMATU" },
    .{ .name = "sceVoiceChatCreateRequest", .function = trace.wrap("sceVoiceChatCreateRequest", &services.offline), .expect_id = "hR8-CKMl2JQ" },
    .{ .name = "sceVoiceChatRequestJoinPlayerSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestJoinPlayerSessionVoiceChatChannel", &services.offline), .expect_id = "X3BWlTuErbk" },
    .{ .name = "sceVoiceChatRequestLeaveGameSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestLeaveGameSessionVoiceChatChannel", &services.offline), .expect_id = "S+mOdmysfhw" },
    .{ .name = "sceVoiceChatRegisterHandlers", .function = trace.wrap("sceVoiceChatRegisterHandlers", &services.offline), .expect_id = "Ptmkf9UnWBg" },
    .{ .name = "sceVoiceChatRequestUnregisterSession", .function = trace.wrap("sceVoiceChatRequestUnregisterSession", &services.offline), .expect_id = "q75YGaxUT3s" },
    .{ .name = "sceVoiceChatRequestCreatePlayerSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestCreatePlayerSessionVoiceChatChannel", &services.offline), .expect_id = "sW3km27c12M" },
    .{ .name = "sceVoiceChatRequestJoinGameSessionVoiceChatChannel", .function = trace.wrap("sceVoiceChatRequestJoinGameSessionVoiceChatChannel", &services.offline), .expect_id = "hpG+mR4EbpE" },
    .{ .name = "sceVoiceChatInitialize", .function = trace.wrap("sceVoiceChatInitialize", &services.offline), .expect_id = "spdS-hedavE" },
    .{ .name = "sceVoiceChatTerminate", .function = trace.wrap("sceVoiceChatTerminate", &services.offline), .expect_id = "j43P62s5SX4" },
    .{ .name = "sceVoiceChatProcessEvent", .function = trace.wrap("sceVoiceChatProcessEvent", &services.offline), .expect_id = "CscDZAFA5+c" },
};

const libSceContentExport_exports = [_]symbols.Export{
    .{ .name = "sceContentExportFinish", .function = trace.wrap("sceContentExportFinish", &services.absent), .expect_id = "tb3cZTCl8Ps" },
    .{ .name = "sceContentExportStart", .function = trace.wrap("sceContentExportStart", &services.absent), .expect_id = "FCygF4Ec4so" },
    .{ .name = "sceContentExportFromData", .function = trace.wrap("sceContentExportFromData", &services.absent), .expect_id = "AOWqIYsgVHs" },
    .{ .name = "sceContentExportTerm", .function = trace.wrap("sceContentExportTerm", &services.absent), .expect_id = "+KDWny9Y-6k" },
};

const libSceAudioIn_exports = [_]symbols.Export{
    .{ .name = "sceAudioInHqOpen", .function = trace.wrap("sceAudioInHqOpen", &services.absent), .expect_id = "nya-R5gDYhM" },
};

const libSceShare_exports = [_]symbols.Export{
    .{ .name = "sceShareCaptureScreenshotExtended", .function = trace.wrap("sceShareCaptureScreenshotExtended", &share.capture), .expect_id = "GQTObcITIXI" },
    .{ .name = "sceShareCaptureScreenshot", .function = trace.wrap("sceShareCaptureScreenshot", &share.capture), .expect_id = "ErH6tKS7fzE" },
};

const libSceAudioPropagation_exports = [_]symbols.Export{
    .{ .name = "sceAudioPropagationSystemUnregisterMaterial", .function = trace.wrap("sceAudioPropagationSystemUnregisterMaterial", &propagation.unregisterMaterial), .expect_id = "XKCN4gpeYsM" },
    .{ .name = "sceAudioPropagationSystemSetRays", .function = trace.wrap("sceAudioPropagationSystemSetRays", &propagation.systemSetRays), .expect_id = "VlBT16890mA" },
    .{ .name = "sceAudioPropagationPortalDestroy", .function = trace.wrap("sceAudioPropagationPortalDestroy", &propagation.destroyPortal), .expect_id = "ZQXE-xS6MTE" },
    .{ .name = "sceAudioPropagationSystemSetAttributes", .function = trace.wrap("sceAudioPropagationSystemSetAttributes", &propagation.systemAttributes), .expect_id = "kIdb+iQUzCs" },
    .{ .name = "sceAudioPropagationSourceSetAudioPaths", .function = trace.wrap("sceAudioPropagationSourceSetAudioPaths", &propagation.sourceSetPaths), .expect_id = "5vzOS2pHMFc" },
    .{ .name = "sceAudioPropagationSystemCreate", .function = trace.wrap("sceAudioPropagationSystemCreate", &propagation.createSystem), .expect_id = "aNEqtSHdUSo" },
    .{ .name = "sceAudioPropagationSystemRegisterMaterial", .function = trace.wrap("sceAudioPropagationSystemRegisterMaterial", &propagation.registerMaterial), .expect_id = "CPLV6G-eXmk" },
    .{ .name = "sceAudioPropagationPortalSetAttributes", .function = trace.wrap("sceAudioPropagationPortalSetAttributes", &propagation.portalAttributes), .expect_id = "WXMhENV2NcA" },
    .{ .name = "sceAudioPropagationPortalCreate", .function = trace.wrap("sceAudioPropagationPortalCreate", &propagation.createPortal), .expect_id = "b-dYXrjSNZU" },
    .{ .name = "sceAudioPropagationRoomDestroy", .function = trace.wrap("sceAudioPropagationRoomDestroy", &propagation.destroyRoom), .expect_id = "S0JwP2AFTTE" },
    .{ .name = "sceAudioPropagationSystemDestroy", .function = trace.wrap("sceAudioPropagationSystemDestroy", &propagation.destroySystem), .expect_id = "x5VPqg5iyAk" },
    .{ .name = "sceAudioPropagationSourceCreate", .function = trace.wrap("sceAudioPropagationSourceCreate", &propagation.createSource), .expect_id = "d84otraxt2s" },
    .{ .name = "sceAudioPropagationSourceSetAttributes", .function = trace.wrap("sceAudioPropagationSourceSetAttributes", &propagation.sourceAttributes), .expect_id = "-wsUTr31yeg" },
    .{ .name = "sceAudioPropagationSourceGetRays", .function = trace.wrap("sceAudioPropagationSourceGetRays", &propagation.sourceGetRays), .expect_id = "aKJZx7wCma8" },
    .{ .name = "sceAudioPropagationSystemQueryMemory", .function = trace.wrap("sceAudioPropagationSystemQueryMemory", &propagation.queryMemory), .expect_id = "7xyAxrusLko" },
    .{ .name = "sceAudioPropagationSourceGetAudioPathCount", .function = trace.wrap("sceAudioPropagationSourceGetAudioPathCount", &propagation.sourceGetPathCount), .expect_id = "G+QLTfyLMYk" },
    .{ .name = "sceAudioPropagationSystemGetRays", .function = trace.wrap("sceAudioPropagationSystemGetRays", &propagation.systemGetRays), .expect_id = "ht-QXT3zGxo" },
    .{ .name = "sceAudioPropagationSourceDestroy", .function = trace.wrap("sceAudioPropagationSourceDestroy", &propagation.destroySource), .expect_id = "wkseM3LWPuc" },
    .{ .name = "sceAudioPropagationSourceRender", .function = trace.wrap("sceAudioPropagationSourceRender", &propagation.render), .expect_id = "hhz9pITnC8k" },
    .{ .name = "sceAudioPropagationSourceGetAudioPath", .function = trace.wrap("sceAudioPropagationSourceGetAudioPath", &propagation.sourceGetPath), .expect_id = "eEeKqFeNI3o" },
    .{ .name = "sceAudioPropagationRoomCreate", .function = trace.wrap("sceAudioPropagationRoomCreate", &propagation.createRoom), .expect_id = "8bI5h8req30" },
    .{ .name = "sceAudioPropagationSourceCalculateAudioPaths", .function = trace.wrap("sceAudioPropagationSourceCalculateAudioPaths", &propagation.sourceCalculatePaths), .expect_id = "PBcrVpEqUVY" },
};

const libSceSharePlay_exports = [_]symbols.Export{
    .{ .name = "sceSharePlayTerminate", .function = trace.wrap("sceSharePlayTerminate", &services.offline), .expect_id = "UaLjloJinow" },
};

const libScePsml_exports = [_]symbols.Export{
    .{ .name = "scePsmlMfsrGetContextBufferRequirement800M3_2", .function = trace.wrap("scePsmlMfsrGetContextBufferRequirement800M3_2", &services.absent), .expect_id = "ArakEpzsZo0" },
    .{ .name = "scePsmlMfsrCreateContext800M3_2", .function = trace.wrap("scePsmlMfsrCreateContext800M3_2", &services.absent), .expect_id = "gxv3i+MTEzU" },
};

pub fn register(db: *symbols.Database, allocator: @import("std").mem.Allocator) symbols.Error!void {
    try db.addLibrary(allocator, .{ .name = "libkernel" }, .{ .name = "libkernel" }, &.{
        .{ .name = "scePthreadCondSignalto", .function = trace.wrap("scePthreadCondSignalto", &services.absent), .expect_id = "o69RpYO-Mu0" },
    });
    try db.addLibrary(allocator, .{ .name = "libSceRudp" }, .{ .name = "libSceRudp" }, &libSceRudp_exports);
    try db.addLibrary(allocator, .{ .name = "libSceVoiceChat" }, .{ .name = "libSceVoiceChat" }, &libSceVoiceChat_exports);
    try db.addLibrary(allocator, .{ .name = "libSceContentExport" }, .{ .name = "libSceContentExport" }, &libSceContentExport_exports);
    try db.addLibrary(allocator, .{ .name = "libSceAudioIn" }, .{ .name = "libSceAudioIn" }, &libSceAudioIn_exports);
    try db.addLibrary(allocator, .{ .name = "libSceShare" }, .{ .name = "libSceShare" }, &libSceShare_exports);
    try db.addLibrary(allocator, .{ .name = "libSceAudioPropagation" }, .{ .name = "libSceAudioPropagation" }, &libSceAudioPropagation_exports);
    try db.addLibrary(allocator, .{ .name = "libSceSharePlay" }, .{ .name = "libSceSharePlay" }, &libSceSharePlay_exports);
    try db.addLibrary(allocator, .{ .name = "libScePsml" }, .{ .name = "libScePsml" }, &libScePsml_exports);
}
