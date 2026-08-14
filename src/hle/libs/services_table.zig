// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
//
//! Bindings for the services a shipped title asks for and this machine
//! does not have. Generated from the identifiers such a title imports and
//! the published names they hash to; what each answer means is in
//! services.zig, where it can be read without a thousand lines in the way.

const services = @import("services.zig");
const av_player = @import("av_player.zig");
const font = @import("font.zig");
const platform_services = @import("platform_services.zig");
const playgo = @import("playgo.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");

pub const acm_exports = [_]symbols.Export{
    .{ .name = "sceAcmContextCreate", .function = trace.wrap("sceAcmContextCreate", &services.absent), .expect_id = "ZIXln2K3XMk" },
    .{ .name = "sceAcmContextDestroy", .function = trace.wrap("sceAcmContextDestroy", &services.absent), .expect_id = "jBgBjAj02R8" },
    .{ .name = "sceAcmBatchWait", .function = trace.wrap("sceAcmBatchWait", &services.absent), .expect_id = "RLN3gRlXJLE" },

    .{ .name = "sceAcm_ConvReverb_SharedInput", .function = trace.wrap("sceAcm_ConvReverb_SharedInput", &services.absent), .expect_id = "u70oWo92SYQ" },
    .{ .name = "sceAcmBatchStartBuffers", .function = trace.wrap("sceAcmBatchStartBuffers", &services.absent), .expect_id = "8fe55ktlNVo" },
    .{ .name = "sceAcm_FFT", .function = trace.wrap("sceAcm_FFT", &services.absent), .expect_id = "KovqaFbmtsM" },
};

pub const agc_exports = [_]symbols.Export{
    .{ .name = "libSceAgc:7Wa3aeJgeVU", .function = trace.wrap("libSceAgc:7Wa3aeJgeVU", &services.accept), .id_override = "7Wa3aeJgeVU" },
    .{ .name = "libSceAgc:rP5xLdOf26k", .function = trace.wrap("libSceAgc:rP5xLdOf26k", &services.accept), .id_override = "rP5xLdOf26k" },
    .{ .name = "libSceAgc:HV4j+E0MBHE", .function = trace.wrap("libSceAgc:HV4j+E0MBHE", &services.accept), .id_override = "HV4j+E0MBHE" },
    .{ .name = "libSceAgc:k0E7vkgqAuE", .function = trace.wrap("libSceAgc:k0E7vkgqAuE", &services.accept), .id_override = "k0E7vkgqAuE" },
    .{ .name = "libSceAgc:gQkqkLttcpw", .function = trace.wrap("libSceAgc:gQkqkLttcpw", &services.accept), .id_override = "gQkqkLttcpw" },
    .{ .name = "libSceAgc:qj7QZpgr9Uw", .function = trace.wrap("libSceAgc:qj7QZpgr9Uw", &services.accept), .id_override = "qj7QZpgr9Uw" },
    .{ .name = "libSceAgc:zARR5aCmkoY", .function = trace.wrap("libSceAgc:zARR5aCmkoY", &services.accept), .id_override = "zARR5aCmkoY" },
};

pub const ajm_exports = [_]symbols.Export{
    .{ .name = "sceAjmStrError", .function = trace.wrap("sceAjmStrError", &services.absent), .expect_id = "AxhcqVv5AYU" },
    .{ .name = "sceAjmBatchJobClearContext", .function = trace.wrap("sceAjmBatchJobClearContext", &services.absent), .expect_id = "uJ3m8INuikg" },
};

pub const ampr_exports = [_]symbols.Export{
    .{ .name = "sceAmprCommandBufferDestructor", .function = trace.wrap("sceAmprCommandBufferDestructor", &services.absent), .expect_id = "GuchCTefuZw" },
    .{ .name = "sceAmprCommandBufferClearBuffer", .function = trace.wrap("sceAmprCommandBufferClearBuffer", &services.absent), .expect_id = "ULvXMDz56po" },
    .{ .name = "sceAmprCommandBufferGetType", .function = trace.wrap("sceAmprCommandBufferGetType", &services.absent), .expect_id = "VEDMaQmJZng" },
    .{ .name = "sceAmprCommandBufferGetSize", .function = trace.wrap("sceAmprCommandBufferGetSize", &services.absent), .expect_id = "tZDDEo2tE5k" },
    .{ .name = "sceAmprCommandBufferGetBufferBaseAddress", .function = trace.wrap("sceAmprCommandBufferGetBufferBaseAddress", &services.absent), .expect_id = "RPCAhx-aabE" },
    .{ .name = "sceAmprCommandBufferGetNumCommands", .function = trace.wrap("sceAmprCommandBufferGetNumCommands", &services.absent), .expect_id = "gzndltBEzWc" },
    .{ .name = "sceAmprCommandBufferGetCurrentOffset", .function = trace.wrap("sceAmprCommandBufferGetCurrentOffset", &services.absent), .expect_id = "GnxKOHEawhk" },
    .{ .name = "sceAmprCommandBufferWaitOnAddress_04_00", .function = trace.wrap("sceAmprCommandBufferWaitOnAddress_04_00", &services.absent), .expect_id = "DLfoNxTFNVk" },
    .{ .name = "sceAmprCommandBufferWaitOnCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWaitOnCounter_04_00", &services.absent), .expect_id = "cQb8Zr8Q0Y0" },
    .{ .name = "sceAmprCommandBufferWriteAddress_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddress_04_00", &services.absent), .expect_id = "j0+3uJMxYJY" },
    .{ .name = "sceAmprCommandBufferWriteAddressFromTimeCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddressFromTimeCounter_04_00", &services.absent), .expect_id = "bt3LHR9xjK4" },
    .{ .name = "sceAmprCommandBufferWriteAddressFromCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddressFromCounter_04_00", &services.absent), .expect_id = "t4ExS+SwLjs" },
    .{ .name = "sceAmprCommandBufferWriteAddressFromCounterPair_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddressFromCounterPair_04_00", &services.absent), .expect_id = "enZm-6GjWqw" },
    .{ .name = "sceAmprCommandBufferWriteCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWriteCounter_04_00", &services.absent), .expect_id = "jK+yuYCI7MA" },
    .{ .name = "sceAmprCommandBufferWriteKernelEventQueue_04_00", .function = trace.wrap("sceAmprCommandBufferWriteKernelEventQueue_04_00", &services.absent), .expect_id = "H896Pt-yB4I" },
    .{ .name = "sceAmprCommandBufferConstructNop", .function = trace.wrap("sceAmprCommandBufferConstructNop", &services.absent), .expect_id = "GmOguNIsuKk" },
    .{ .name = "sceAmprCommandBufferNop", .function = trace.wrap("sceAmprCommandBufferNop", &services.absent), .expect_id = "tNn5WBkta60" },
    .{ .name = "sceAmprCommandBufferNopWithData", .function = trace.wrap("sceAmprCommandBufferNopWithData", &services.absent), .expect_id = "pFQ9UHpO52s" },
    .{ .name = "sceAmprCommandBufferConstructMarker", .function = trace.wrap("sceAmprCommandBufferConstructMarker", &services.absent), .expect_id = "4UkZbYKVF7c" },
    .{ .name = "sceAmprCommandBufferSetMarkerWithColor", .function = trace.wrap("sceAmprCommandBufferSetMarkerWithColor", &services.absent), .expect_id = "sWbST0oQKsc" },
    .{ .name = "sceAmprCommandBufferSetMarker", .function = trace.wrap("sceAmprCommandBufferSetMarker", &services.absent), .expect_id = "4quckD2y7Pg" },
    .{ .name = "sceAmprCommandBufferPushMarkerWithColor", .function = trace.wrap("sceAmprCommandBufferPushMarkerWithColor", &services.absent), .expect_id = "f12ObAMEi9A" },
    .{ .name = "sceAmprCommandBufferPushMarker", .function = trace.wrap("sceAmprCommandBufferPushMarker", &services.absent), .expect_id = "dXPaz65HNmk" },
    .{ .name = "sceAmprCommandBufferPopMarker", .function = trace.wrap("sceAmprCommandBufferPopMarker", &services.absent), .expect_id = "mv0O8Zg0woU" },
    .{ .name = "sceAmprAprCommandBufferDestructor", .function = trace.wrap("sceAmprAprCommandBufferDestructor", &services.absent), .expect_id = "Qs1xtplKo0U" },
    .{ .name = "sceAmprAprCommandBufferReadFileGather", .function = trace.wrap("sceAmprAprCommandBufferReadFileGather", &services.absent), .expect_id = "mZSbNJVJpV8" },
    .{ .name = "sceAmprAprCommandBufferReadFileScatter", .function = trace.wrap("sceAmprAprCommandBufferReadFileScatter", &services.absent), .expect_id = "Jg-AgkdJHkk" },
    .{ .name = "sceAmprAprCommandBufferReadFileGatherScatter", .function = trace.wrap("sceAmprAprCommandBufferReadFileGatherScatter", &services.absent), .expect_id = "BVmR1H8l+XI" },
    .{ .name = "sceAmprAprCommandBufferResetGatherScatterState", .function = trace.wrap("sceAmprAprCommandBufferResetGatherScatterState", &services.absent), .expect_id = "YPxkUDhgoNI" },
    .{ .name = "sceAmprAprCommandBufferMapBegin", .function = trace.wrap("sceAmprAprCommandBufferMapBegin", &services.absent), .expect_id = "Eul7AGEpjLo" },
    .{ .name = "sceAmprAprCommandBufferMapDirectBegin", .function = trace.wrap("sceAmprAprCommandBufferMapDirectBegin", &services.absent), .expect_id = "bFEs0Gs6D2A" },
    .{ .name = "sceAmprAprCommandBufferMapEnd", .function = trace.wrap("sceAmprAprCommandBufferMapEnd", &services.absent), .expect_id = "X169CE6G3Y4" },
    .{ .name = "sceAmprMeasureCommandSizeWaitOnAddress_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWaitOnAddress_04_00", &services.absent), .expect_id = "0BMj1hgG+kE" },
    .{ .name = "sceAmprMeasureCommandSizeWaitOnCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWaitOnCounter_04_00", &services.absent), .expect_id = "ClnsFLLLcss" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddress_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddress_04_00", &services.absent), .expect_id = "4fgtGfXDrFc" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddressFromTimeCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddressFromTimeCounter_04_00", &services.absent), .expect_id = "gAtc79UTt5E" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddressFromCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddressFromCounter_04_00", &services.absent), .expect_id = "JYd9g9L+TmE" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddressFromCounterPair_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddressFromCounterPair_04_00", &services.absent), .expect_id = "2Hw8gjMdwSY" },
    .{ .name = "sceAmprMeasureCommandSizeWriteCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteCounter_04_00", &services.absent), .expect_id = "I-Qm+MEso5c" },
    .{ .name = "sceAmprMeasureCommandSizeWriteKernelEventQueue_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteKernelEventQueue_04_00", &services.absent), .expect_id = "sSAUCCU1dv4" },
    .{ .name = "sceAmprMeasureCommandSizeNop", .function = trace.wrap("sceAmprMeasureCommandSizeNop", &services.absent), .expect_id = "NNIZ-FMyz3M" },
    .{ .name = "sceAmprMeasureCommandSizeNopWithData", .function = trace.wrap("sceAmprMeasureCommandSizeNopWithData", &services.absent), .expect_id = "Xp85BP3+BBI" },
    .{ .name = "sceAmprMeasureCommandSizeReadFile", .function = trace.wrap("sceAmprMeasureCommandSizeReadFile", &services.absent), .expect_id = "vWU-odnS+fU" },
    .{ .name = "sceAmprMeasureCommandSizeReadFileGather", .function = trace.wrap("sceAmprMeasureCommandSizeReadFileGather", &services.absent), .expect_id = "qesF88X4DRg" },
    .{ .name = "sceAmprMeasureCommandSizeReadFileScatter", .function = trace.wrap("sceAmprMeasureCommandSizeReadFileScatter", &services.absent), .expect_id = "7nXGDGMXSqo" },
    .{ .name = "sceAmprMeasureCommandSizeReadFileGatherScatter", .function = trace.wrap("sceAmprMeasureCommandSizeReadFileGatherScatter", &services.absent), .expect_id = "DXmgc5op8Yw" },
    .{ .name = "sceAmprMeasureCommandSizeResetGatherScatterState", .function = trace.wrap("sceAmprMeasureCommandSizeResetGatherScatterState", &services.absent), .expect_id = "rddQYXM0CjM" },
    .{ .name = "sceAmprMeasureCommandSizeMapBegin", .function = trace.wrap("sceAmprMeasureCommandSizeMapBegin", &services.absent), .expect_id = "kdFImtTD0hc" },
    .{ .name = "sceAmprMeasureCommandSizeMapDirectBegin", .function = trace.wrap("sceAmprMeasureCommandSizeMapDirectBegin", &services.absent), .expect_id = "qvbdJc7bG+s" },
    .{ .name = "sceAmprMeasureCommandSizeMapEnd", .function = trace.wrap("sceAmprMeasureCommandSizeMapEnd", &services.absent), .expect_id = "iwTNhyaemnw" },
    .{ .name = "sceAmprMeasureCommandSizeSetMarkerWithColor", .function = trace.wrap("sceAmprMeasureCommandSizeSetMarkerWithColor", &services.absent), .expect_id = "tmfr97+ED5I" },
    .{ .name = "sceAmprMeasureCommandSizeSetMarker", .function = trace.wrap("sceAmprMeasureCommandSizeSetMarker", &services.absent), .expect_id = "VGkEj4d6-Kg" },
    .{ .name = "sceAmprMeasureCommandSizePushMarkerWithColor", .function = trace.wrap("sceAmprMeasureCommandSizePushMarkerWithColor", &services.absent), .expect_id = "3OfeY4pzDV0" },
    .{ .name = "sceAmprMeasureCommandSizePushMarker", .function = trace.wrap("sceAmprMeasureCommandSizePushMarker", &services.absent), .expect_id = "0RdLmAh7WVo" },
    .{ .name = "sceAmprMeasureCommandSizePopMarker", .function = trace.wrap("sceAmprMeasureCommandSizePopMarker", &services.absent), .expect_id = "pbnNnahE8vk" },
};

pub const audioout2_exports = [_]symbols.Export{
    .{ .name = "sceAudioOut2PortGetState", .function = trace.wrap("sceAudioOut2PortGetState", &services.absent), .expect_id = "gatEUKG+Ea4" },
};

pub const audiodec_exports = [_]symbols.Export{
    // Codec type 1 (ATRAC9) is optional for this title's playback path. Keep
    // the library lifecycle coherent so it can create a decoder when audio is
    // present, instead of disabling the whole sound subsystem at startup.
    .{ .name = "sceAudiodecInitLibrary", .function = trace.wrap("sceAudiodecInitLibrary", &services.accept), .expect_id = "VjhsmxpcezI" },
    .{ .name = "sceAudiodecTermLibrary", .function = trace.wrap("sceAudiodecTermLibrary", &services.accept), .expect_id = "h5jSB2QIDV0" },
    .{ .name = "sceAudiodecDeleteDecoder", .function = trace.wrap("sceAudiodecDeleteDecoder", &services.absent), .expect_id = "Tp+ZEy69mLk" },
    .{ .name = "sceAudiodecDecode", .function = trace.wrap("sceAudiodecDecode", &services.absent), .expect_id = "KHXHMDLkILw" },
    .{ .name = "sceAudiodecClearContext", .function = trace.wrap("sceAudiodecClearContext", &services.absent), .expect_id = "6Vf9WTLDoss" },
    .{ .name = "sceAudiodecCreateDecoder", .function = trace.wrap("sceAudiodecCreateDecoder", &services.absent), .expect_id = "O3f1sLMWRvs" },
};

pub const avplayer_exports = [_]symbols.Export{
    .{ .name = "sceAvPlayerAddSource", .function = trace.wrap("sceAvPlayerAddSource", &av_player.addSource), .expect_id = "KMcEa+rHsIo" },
    .{ .name = "sceAvPlayerCurrentTime", .function = trace.wrap("sceAvPlayerCurrentTime", &av_player.currentTime), .expect_id = "wwM99gjFf1Y" },
    .{ .name = "sceAvPlayerSetTrickSpeed", .function = trace.wrap("sceAvPlayerSetTrickSpeed", &av_player.setTrickSpeed), .expect_id = "av8Z++94rs0" },
    .{ .name = "sceAvPlayerGetStreamInfo", .function = trace.wrap("sceAvPlayerGetStreamInfo", &av_player.getStreamInfo), .expect_id = "d8FcbzfAdQw" },
    .{ .name = "sceAvPlayerDisableStream", .function = trace.wrap("sceAvPlayerDisableStream", &av_player.disableStream), .expect_id = "BOVKAzRmuTQ" },
    .{ .name = "sceAvPlayerInit", .function = trace.wrap("sceAvPlayerInit", &av_player.init), .expect_id = "aS66RI0gGgo" },
};

pub const coredump_exports = [_]symbols.Export{
    .{ .name = "sceCoredumpRegisterCoredumpHandler", .function = trace.wrap("sceCoredumpRegisterCoredumpHandler", &services.accept), .expect_id = "8zLSfEfW5AU" },
    .{ .name = "sceCoredumpSetUserDataType", .function = trace.wrap("sceCoredumpSetUserDataType", &services.accept), .expect_id = "Uxqkdta7wEg" },
    .{ .name = "sceCoredumpWriteUserData", .function = trace.wrap("sceCoredumpWriteUserData", &services.accept), .expect_id = "Dbbkj6YHWdo" },
};

pub const camera2_exports = [_]symbols.Export{
    .{ .name = "sceCamera2IsAttached", .function = trace.wrap("sceCamera2IsAttached", &services.notAttached), .expect_id = "2v21-m4gljU" },
    .{ .name = "sceCamera2Open", .function = trace.wrap("sceCamera2Open", &services.noDevice), .expect_id = "dmLUJh3bVTc" },
    .{ .name = "sceCamera2Stop", .function = trace.wrap("sceCamera2Stop", &services.noDevice), .expect_id = "TZWR3p6XxXk" },
    .{ .name = "sceCamera2Close", .function = trace.wrap("sceCamera2Close", &services.noDevice), .expect_id = "uBRW3tEoWWM" },
    .{ .name = "sceCamera2SetConfig", .function = trace.wrap("sceCamera2SetConfig", &services.noDevice), .expect_id = "O5x-G9Rqwx4" },
    .{ .name = "sceCamera2Start", .function = trace.wrap("sceCamera2Start", &services.noDevice), .expect_id = "eGkcUia48ts" },
    .{ .name = "sceCamera2GetExposureGain", .function = trace.wrap("sceCamera2GetExposureGain", &services.noDevice), .expect_id = "c9XZGDF1OcM" },
    .{ .name = "sceCamera2SetExposureGain", .function = trace.wrap("sceCamera2SetExposureGain", &services.noDevice), .expect_id = "8MEjogxPrv0" },
    .{ .name = "sceCamera2GetWhiteBalance", .function = trace.wrap("sceCamera2GetWhiteBalance", &services.noDevice), .expect_id = "n+R7PGJa6MI" },
    .{ .name = "sceCamera2SetWhiteBalance", .function = trace.wrap("sceCamera2SetWhiteBalance", &services.noDevice), .expect_id = "AfIDd+2ycTs" },
    .{ .name = "sceCamera2GetGamma", .function = trace.wrap("sceCamera2GetGamma", &services.noDevice), .expect_id = "gJqqsinextg" },
    .{ .name = "sceCamera2SetGamma", .function = trace.wrap("sceCamera2SetGamma", &services.noDevice), .expect_id = "pfiqU2f6PQY" },
    .{ .name = "sceCamera2GetSaturation", .function = trace.wrap("sceCamera2GetSaturation", &services.noDevice), .expect_id = "DAycoVmY3Mw" },
    .{ .name = "sceCamera2SetSaturation", .function = trace.wrap("sceCamera2SetSaturation", &services.noDevice), .expect_id = "TzkL-nUWfaQ" },
    .{ .name = "sceCamera2GetContrast", .function = trace.wrap("sceCamera2GetContrast", &services.noDevice), .expect_id = "1-IJHxzRJGw" },
    .{ .name = "sceCamera2SetContrast", .function = trace.wrap("sceCamera2SetContrast", &services.noDevice), .expect_id = "66IVWcdNHyI" },
    .{ .name = "sceCamera2GetSharpness", .function = trace.wrap("sceCamera2GetSharpness", &services.noDevice), .expect_id = "vPi3gSzw79M" },
    .{ .name = "sceCamera2SetSharpness", .function = trace.wrap("sceCamera2SetSharpness", &services.noDevice), .expect_id = "2zCd8XDOe-Y" },
    .{ .name = "sceCamera2GetHue", .function = trace.wrap("sceCamera2GetHue", &services.noDevice), .expect_id = "T8jy0JWa210" },
    .{ .name = "sceCamera2SetHue", .function = trace.wrap("sceCamera2SetHue", &services.noDevice), .expect_id = "gB+OkFvkSXE" },
};

pub const errordialog_exports = [_]symbols.Export{
    .{ .name = "sceErrorDialogInitialize", .function = trace.wrap("sceErrorDialogInitialize", &services.absent), .expect_id = "I88KChlynSs" },
    .{ .name = "sceErrorDialogOpen", .function = trace.wrap("sceErrorDialogOpen", &services.absent), .expect_id = "M2ZF-ClLhgY" },
    .{ .name = "sceErrorDialogUpdateStatus", .function = trace.wrap("sceErrorDialogUpdateStatus", &services.absent), .expect_id = "WWiGuh9XfgQ" },
    .{ .name = "sceErrorDialogTerminate", .function = trace.wrap("sceErrorDialogTerminate", &services.absent), .expect_id = "9XAxK2PMwk8" },
    .{ .name = "sceErrorDialogClose", .function = trace.wrap("sceErrorDialogClose", &services.accept), .expect_id = "ekXHb1kDBl0" },
    .{ .name = "sceErrorDialogGetStatus", .function = trace.wrap("sceErrorDialogGetStatus", &services.saveDataDialogFinished), .expect_id = "t2FvHRXzgqk" },
};

pub const gamelivestreaming_exports = [_]symbols.Export{
    .{ .name = "sceGameLiveStreamingInitialize", .function = trace.wrap("sceGameLiveStreamingInitialize", &services.offline), .expect_id = "kvYEw2lBndk" },
    .{ .name = "sceGameLiveStreamingTerminate", .function = trace.wrap("sceGameLiveStreamingTerminate", &services.offline), .expect_id = "9yK6Fk8mKOQ" },
    .{ .name = "sceGameLiveStreamingGetCurrentStatus2", .function = trace.wrap("sceGameLiveStreamingGetCurrentStatus2", &services.offline), .expect_id = "lK8dLBNp9OE" },
    .{ .name = "sceGameLiveStreamingGetProgramInfo", .function = trace.wrap("sceGameLiveStreamingGetProgramInfo", &services.offline), .expect_id = "OIIm19xu+NM" },
};

pub const gameupdate_exports = [_]symbols.Export{
    .{ .name = "sceGameUpdateInitialize", .function = trace.wrap("sceGameUpdateInitialize", &services.gameUpdateInitialize), .expect_id = "YJtKLttI9fM" },
    .{ .name = "sceGameUpdateTerminate", .function = trace.wrap("sceGameUpdateTerminate", &services.gameUpdateTerminate), .expect_id = "NSH-C-OmoNI" },
    .{ .name = "sceGameUpdateCreateRequest", .function = trace.wrap("sceGameUpdateCreateRequest", &services.gameUpdateCreateRequest), .expect_id = "UvcvKaFvupA" },
    .{ .name = "sceGameUpdateCheck", .function = trace.wrap("sceGameUpdateCheck", &services.gameUpdateCheck), .expect_id = "LYVV9z8+owM" },
    .{ .name = "sceGameUpdateAbortRequest", .function = trace.wrap("sceGameUpdateAbortRequest", &services.gameUpdateAbortRequest), .expect_id = "d1CNGEOaK28" },
    .{ .name = "sceGameUpdateDeleteRequest", .function = trace.wrap("sceGameUpdateDeleteRequest", &services.gameUpdateDeleteRequest), .expect_id = "bcCyjHN5sn0" },
    .{ .name = "sceGameUpdateGetAddcontLatestVersion", .function = trace.wrap("sceGameUpdateGetAddcontLatestVersion", &services.gameUpdateGetAddcontLatestVersion), .expect_id = "0g0+Oq9xcI0" },
};

pub const hmd2_exports = [_]symbols.Export{
    .{ .name = "sceHmd2ReprojectionSetRenderConfig", .function = trace.wrap("sceHmd2ReprojectionSetRenderConfig", &services.noDevice), .expect_id = "hA9LshbSkzw" },
    .{ .name = "sceHmd2GetDeviceInformation", .function = trace.wrap("sceHmd2GetDeviceInformation", &services.noDevice), .expect_id = "bIi4YUfSRys" },
    .{ .name = "sceHmd2GetDeviceInformationByHandle", .function = trace.wrap("sceHmd2GetDeviceInformationByHandle", &services.noDevice), .expect_id = "4BlE4IPXP0Q" },
    .{ .name = "sceHmd2Open", .function = trace.wrap("sceHmd2Open", &services.noDevice), .expect_id = "f3kPeoTZnIE" },
    .{ .name = "sceHmd2GetFieldOfViewWithoutHandle", .function = trace.wrap("sceHmd2GetFieldOfViewWithoutHandle", &services.noDevice), .expect_id = "gF8+lvc7GuQ" },
    .{ .name = "sceHmd2ReprojectionBeginFrame", .function = trace.wrap("sceHmd2ReprojectionBeginFrame", &services.noDevice), .expect_id = "Ocf081WpBpA" },
    .{ .name = "sceHmd2ReprojectionEnableMirroring", .function = trace.wrap("sceHmd2ReprojectionEnableMirroring", &services.noDevice), .expect_id = "Qx7SkcgAzok" },
    .{ .name = "sceHmd2ReprojectionSetMirroringOption", .function = trace.wrap("sceHmd2ReprojectionSetMirroringOption", &services.noDevice), .expect_id = "+seEJVlljr0" },
    .{ .name = "sceHmd2ReprojectionDisableMirroring", .function = trace.wrap("sceHmd2ReprojectionDisableMirroring", &services.noDevice), .expect_id = "asilo8VNGvg" },
    .{ .name = "sceHmd2ReprojectionGetPredictedDisplayTime", .function = trace.wrap("sceHmd2ReprojectionGetPredictedDisplayTime", &services.noDevice), .expect_id = "SVEG+1D7qHA" },
    .{ .name = "sceHmd2ReprojectionSetParam", .function = trace.wrap("sceHmd2ReprojectionSetParam", &services.noDevice), .expect_id = "xMo9ENEu2E0" },
    .{ .name = "sceHmd2SetVibration", .function = trace.wrap("sceHmd2SetVibration", &services.noDevice), .expect_id = "Al4qjNREVQQ" },
    .{ .name = "sceHmd2Initialize", .function = trace.wrap("sceHmd2Initialize", &services.noDevice), .expect_id = "c812oYs7Vsc" },
    .{ .name = "sceHmd2ReprojectionQueryBufferSizeAlign", .function = trace.wrap("sceHmd2ReprojectionQueryBufferSizeAlign", &services.noDevice), .expect_id = "U-CnbmeyYaA" },
    .{ .name = "sceHmd2ReprojectionQueryDisplayBufferSizeAlign", .function = trace.wrap("sceHmd2ReprojectionQueryDisplayBufferSizeAlign", &services.noDevice), .expect_id = "-C2nkoEYOnU" },
    .{ .name = "sceHmd2ReprojectionGetMirroringWorkMemorySizeAlign", .function = trace.wrap("sceHmd2ReprojectionGetMirroringWorkMemorySizeAlign", &services.noDevice), .expect_id = "Pb1d+j-bBSc" },
    .{ .name = "sceHmd2ReprojectionGetMirroringDisplayBufferSizeAlign", .function = trace.wrap("sceHmd2ReprojectionGetMirroringDisplayBufferSizeAlign", &services.noDevice), .expect_id = "wEO+gMHs9NU" },
    .{ .name = "sceHmd2ReprojectionInitialize", .function = trace.wrap("sceHmd2ReprojectionInitialize", &services.noDevice), .expect_id = "C0rPwER-yxg" },
    .{ .name = "sceHmd2ReprojectionEnableVrMode", .function = trace.wrap("sceHmd2ReprojectionEnableVrMode", &services.noDevice), .expect_id = "VVvFh51o20s" },
    .{ .name = "sceHmd2ReprojectionSetTiming", .function = trace.wrap("sceHmd2ReprojectionSetTiming", &services.noDevice), .expect_id = "FkQX7rjFomk" },
    .{ .name = "sceHmd2ReprojectionDisableVrMode", .function = trace.wrap("sceHmd2ReprojectionDisableVrMode", &services.noDevice), .expect_id = "wj1kOyNF4vM" },
    .{ .name = "sceHmd2ReprojectionGetStatus", .function = trace.wrap("sceHmd2ReprojectionGetStatus", &services.noDevice), .expect_id = "8GkaY2B7opM" },
    .{ .name = "sceHmd2ReprojectionTerminate", .function = trace.wrap("sceHmd2ReprojectionTerminate", &services.noDevice), .expect_id = "4Q11W4M2h5Q" },
    .{ .name = "sceHmd2Close", .function = trace.wrap("sceHmd2Close", &services.noDevice), .expect_id = "oPhtjySuHa8" },
    .{ .name = "sceHmd2Terminate", .function = trace.wrap("sceHmd2Terminate", &services.noDevice), .expect_id = "QU2M1pPNbaY" },
    .{ .name = "sceHmd2GazeGetResult", .function = trace.wrap("sceHmd2GazeGetResult", &services.noDevice), .expect_id = "lAoFUedcfqA" },
    .{ .name = "sceHmd2GazeGetResultForFoveatedRendering", .function = trace.wrap("sceHmd2GazeGetResultForFoveatedRendering", &services.noDevice), .expect_id = "retc+-uRMhk" },
    .{ .name = "libSceHmd2:uv0Ae+jCeWY", .function = trace.wrap("libSceHmd2:uv0Ae+jCeWY", &services.noDevice), .id_override = "uv0Ae+jCeWY" },
    .{ .name = "libSceHmd2:JWBl3Uq6q8k", .function = trace.wrap("libSceHmd2:JWBl3Uq6q8k", &services.noDevice), .id_override = "JWBl3Uq6q8k" },
};

pub const http_exports = [_]symbols.Export{
    .{ .name = "sceHttpUriBuild", .function = trace.wrap("sceHttpUriBuild", &services.offline), .expect_id = "5LZA+KPISVA" },
    .{ .name = "sceHttpAbortRequest", .function = trace.wrap("sceHttpAbortRequest", &services.offline), .expect_id = "hvG6GfBMXg8" },
    .{ .name = "sceHttpSendRequest", .function = trace.wrap("sceHttpSendRequest", &services.offline), .expect_id = "1e2BNwI-XzE" },
    .{ .name = "sceHttpGetLastErrno", .function = trace.wrap("sceHttpGetLastErrno", &services.offline), .expect_id = "0onIrKx9NIE" },
    .{ .name = "sceHttpGetStatusCode", .function = trace.wrap("sceHttpGetStatusCode", &services.offline), .expect_id = "0a2TBNfE3BU" },
    .{ .name = "sceHttpGetResponseContentLength", .function = trace.wrap("sceHttpGetResponseContentLength", &services.offline), .expect_id = "yuO2H2Uvnos" },
    .{ .name = "sceHttpReadData", .function = trace.wrap("sceHttpReadData", &services.offline), .expect_id = "P5pdoykPYTk" },
    .{ .name = "sceHttpWaitRequest", .function = trace.wrap("sceHttpWaitRequest", &services.offline), .expect_id = "qISjDHrxONc" },
    .{ .name = "sceHttpDeleteRequest", .function = trace.wrap("sceHttpDeleteRequest", &services.offline), .expect_id = "qe7oZ+v4PWA" },
    .{ .name = "sceHttpDestroyEpoll", .function = trace.wrap("sceHttpDestroyEpoll", &services.offline), .expect_id = "wYhXVfS2Et4" },
    .{ .name = "sceHttpDeleteConnection", .function = trace.wrap("sceHttpDeleteConnection", &services.offline), .expect_id = "P6A3ytpsiYc" },
    .{ .name = "sceHttpCreateRequestWithURL", .function = trace.wrap("sceHttpCreateRequestWithURL", &services.offline), .expect_id = "Aeu5wVKkF9w" },
    .{ .name = "sceHttpCreateRequestWithURL2", .function = trace.wrap("sceHttpCreateRequestWithURL2", &services.offline), .expect_id = "Cnp77podkCU" },
    .{ .name = "sceHttpSetNonblock", .function = trace.wrap("sceHttpSetNonblock", &services.offline), .expect_id = "s2-NPIvz+iA" },
    .{ .name = "sceHttpCreateEpoll", .function = trace.wrap("sceHttpCreateEpoll", &services.offline), .expect_id = "6381dWF+xsQ" },
    .{ .name = "sceHttpSetEpoll", .function = trace.wrap("sceHttpSetEpoll", &services.offline), .expect_id = "-xm7kZQNpHI" },
    .{ .name = "sceHttpCreateConnectionWithURL", .function = trace.wrap("sceHttpCreateConnectionWithURL", &services.offline), .expect_id = "qgxDBjorUxs" },
    .{ .name = "sceHttpAddRequestHeader", .function = trace.wrap("sceHttpAddRequestHeader", &services.offline), .expect_id = "EY28T2bkN7k" },
    .{ .name = "sceHttpGetAllResponseHeaders", .function = trace.wrap("sceHttpGetAllResponseHeaders", &services.offline), .expect_id = "aCYPMSUIaP8" },
    .{ .name = "sceHttpCreateTemplate", .function = trace.wrap("sceHttpCreateTemplate", &services.offline), .expect_id = "0gYjPTR-6cY" },
    .{ .name = "sceHttpDeleteTemplate", .function = trace.wrap("sceHttpDeleteTemplate", &services.offline), .expect_id = "4I8vEpuEhZ8" },
};

pub const imedialog_exports = [_]symbols.Export{
    .{ .name = "sceImeDialogGetPanelSizeExtended", .function = trace.wrap("sceImeDialogGetPanelSizeExtended", &services.absent), .expect_id = "CRD+jSErEJQ" },
};

pub const json2_exports = [_]symbols.Export{
    .{ .name = "_ZN3sce4Json6ObjectC1Ev", .function = trace.wrap("_ZN3sce4Json6ObjectC1Ev", &services.absent), .expect_id = "OJPTonqdg0I" },
    .{ .name = "_ZN3sce4Json6StringC1EPKc", .function = trace.wrap("_ZN3sce4Json6StringC1EPKc", &services.absent), .expect_id = "9KUZFjI1IxA" },
    .{ .name = "_ZN3sce4Json5ValueC1ERKNS0_6StringE", .function = trace.wrap("_ZN3sce4Json5ValueC1ERKNS0_6StringE", &services.absent), .expect_id = "sZIoMRGO+jk" },
    .{ .name = "_ZN3sce4Json6ObjectixERKNS0_6StringE", .function = trace.wrap("_ZN3sce4Json6ObjectixERKNS0_6StringE", &services.absent), .expect_id = "ERuf9y0DY84" },
    .{ .name = "_ZN3sce4Json5ValueaSERKS1_", .function = trace.wrap("_ZN3sce4Json5ValueaSERKS1_", &services.absent), .expect_id = "4zrm6VrgIAw" },
    .{ .name = "_ZN3sce4Json6StringD1Ev", .function = trace.wrap("_ZN3sce4Json6StringD1Ev", &services.absent), .expect_id = "cG1VE2HMl6c" },
    .{ .name = "_ZN3sce4Json5ValueD1Ev", .function = trace.wrap("_ZN3sce4Json5ValueD1Ev", &services.absent), .expect_id = "WTtYf+cNnXI" },
    .{ .name = "_ZN3sce4Json6ObjectC1ERKS1_", .function = trace.wrap("_ZN3sce4Json6ObjectC1ERKS1_", &services.absent), .expect_id = "a+W7HHlwpBs" },
    .{ .name = "_ZN3sce4Json6ObjectD1Ev", .function = trace.wrap("_ZN3sce4Json6ObjectD1Ev", &services.absent), .expect_id = "5JmzZt8twAo" },
    .{ .name = "_ZN3sce4Json5ValueC1Ev", .function = trace.wrap("_ZN3sce4Json5ValueC1Ev", &services.absent), .expect_id = "qBMjqyBn3OM" },
    .{ .name = "_ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm", .function = trace.wrap("_ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm", &services.absent), .expect_id = "S5JxQnoGF3E" },
    .{ .name = "_ZNK3sce4Json5ValueixEPKc", .function = trace.wrap("_ZNK3sce4Json5ValueixEPKc", &services.absent), .expect_id = "HwDt5lD9Bfo" },
    .{ .name = "_ZNK3sce4Json5Value9getStringEv", .function = trace.wrap("_ZNK3sce4Json5Value9getStringEv", &services.absent), .expect_id = "epJ6x2LV0kU" },
    .{ .name = "_ZNK3sce4Json6String5c_strEv", .function = trace.wrap("_ZNK3sce4Json6String5c_strEv", &services.absent), .expect_id = "L1KAkYWml-M" },
    // JSON's process-wide bootstrap owns no guest-visible result handles. The
    // offline CppWebApi module still initializes it before deciding that no
    // network service is available, so returning ENOSYS here aborts the whole
    // Unity plug-in bootstrap instead of selecting that offline path.
    .{ .name = "_ZN3sce4Json12MemAllocatorC2Ev", .function = trace.wrap("_ZN3sce4Json12MemAllocatorC2Ev", &services.accept), .expect_id = "-hJRce8wn1U" },
    .{ .name = "_ZN3sce4Json14InitParameter2C1Ev", .function = trace.wrap("_ZN3sce4Json14InitParameter2C1Ev", &services.accept), .expect_id = "WSOuge5IsCg" },
    .{ .name = "_ZN3sce4Json14InitParameter212setAllocatorEPNS0_12MemAllocatorEPv", .function = trace.wrap("_ZN3sce4Json14InitParameter212setAllocatorEPNS0_12MemAllocatorEPv", &services.accept), .expect_id = "I2QC8PYhJWY" },
    .{ .name = "_ZN3sce4Json14InitParameter217setFileBufferSizeEm", .function = trace.wrap("_ZN3sce4Json14InitParameter217setFileBufferSizeEm", &services.accept), .expect_id = "Eu95jmqn5Rw" },
    .{ .name = "_ZN3sce4Json11InitializerC1Ev", .function = trace.wrap("_ZN3sce4Json11InitializerC1Ev", &services.accept), .expect_id = "cK6bYHf-Q5E" },
    .{ .name = "_ZN3sce4Json11Initializer10initializeEPKNS0_14InitParameter2E", .function = trace.wrap("_ZN3sce4Json11Initializer10initializeEPKNS0_14InitParameter2E", &services.accept), .expect_id = "IXW-z8pggfg" },
    .{ .name = "_ZN3sce4Json11Initializer9terminateEv", .function = trace.wrap("_ZN3sce4Json11Initializer9terminateEv", &services.accept), .expect_id = "PR5k1penBLM" },
    .{ .name = "_ZN3sce4Json11InitializerD1Ev", .function = trace.wrap("_ZN3sce4Json11InitializerD1Ev", &services.accept), .expect_id = "RujUxbr3haM" },
    .{ .name = "_ZN3sce4Json12MemAllocatorD2Ev", .function = trace.wrap("_ZN3sce4Json12MemAllocatorD2Ev", &services.accept), .expect_id = "OcAgPxcq5Vk" },
};

pub const net_exports = [_]symbols.Export{
    .{ .name = "sceNetInetNtop", .function = trace.wrap("sceNetInetNtop", &services.offline), .expect_id = "9vA2aW+CHuA" },
    .{ .name = "sceNetGetMacAddress", .function = trace.wrap("sceNetGetMacAddress", &services.offline), .expect_id = "6Oc0bLsIYe0" },
    .{ .name = "sceNetGetSockInfo", .function = trace.wrap("sceNetGetSockInfo", &services.offline), .expect_id = "hLuXdjHnhiI" },
    .{ .name = "sceNetResolverStartNtoaMultipleRecords", .function = trace.wrap("sceNetResolverStartNtoaMultipleRecords", &services.offline), .expect_id = "RCCY01Xd+58" },
    .{ .name = "sceNetResolverStartAton", .function = trace.wrap("sceNetResolverStartAton", &services.offline), .expect_id = "Apb4YDxKsRI" },
};

pub const ngs2_exports = [_]symbols.Export{
    .{ .name = "sceNgs2CalcWaveformBlock", .function = trace.wrap("sceNgs2CalcWaveformBlock", &services.absent), .expect_id = "3pCNbVM11UA" },
    .{ .name = "sceNgs2ParseWaveformData", .function = trace.wrap("sceNgs2ParseWaveformData", &services.absent), .expect_id = "hyVLT2VlOYk" },
    .{ .name = "sceNgs2SystemResetOption", .function = trace.wrap("sceNgs2SystemResetOption", &services.absent), .expect_id = "AQkj7C0f3PY" },
    .{ .name = "sceNgs2SystemCreateWithAllocator", .function = trace.wrap("sceNgs2SystemCreateWithAllocator", &services.absent), .expect_id = "mPYgU4oYpuY" },
    .{ .name = "sceNgs2RackCreateWithAllocator", .function = trace.wrap("sceNgs2RackCreateWithAllocator", &services.absent), .expect_id = "U546k6orxQo" },
    .{ .name = "sceNgs2RackGetVoiceHandle", .function = trace.wrap("sceNgs2RackGetVoiceHandle", &services.absent), .expect_id = "MwmHz8pAdAo" },
    .{ .name = "sceNgs2VoiceControl", .function = trace.wrap("sceNgs2VoiceControl", &services.absent), .expect_id = "uu94irFOGpA" },
    .{ .name = "sceNgs2VoiceRunCommands", .function = trace.wrap("sceNgs2VoiceRunCommands", &services.absent), .expect_id = "AbYvTOZ8Pts" },
    .{ .name = "sceNgs2RackDestroy", .function = trace.wrap("sceNgs2RackDestroy", &services.absent), .expect_id = "lCqD7oycmIM" },
    .{ .name = "sceNgs2SystemDestroy", .function = trace.wrap("sceNgs2SystemDestroy", &services.absent), .expect_id = "u-WrYDaJA3k" },
    .{ .name = "sceNgs2SystemRender", .function = trace.wrap("sceNgs2SystemRender", &services.absent), .expect_id = "i0VnXM-C9fc" },
    .{ .name = "sceNgs2PanInit", .function = trace.wrap("sceNgs2PanInit", &services.absent), .expect_id = "xa8oL9dmXkM" },
    .{ .name = "sceNgs2PanGetVolumeMatrix", .function = trace.wrap("sceNgs2PanGetVolumeMatrix", &services.absent), .expect_id = "gbMKV+8Enuo" },
    .{ .name = "sceNgs2VoiceGetStateFlags", .function = trace.wrap("sceNgs2VoiceGetStateFlags", &services.absent), .expect_id = "rEh728kXk3w" },
    .{ .name = "sceNgs2VoiceGetState", .function = trace.wrap("sceNgs2VoiceGetState", &services.absent), .expect_id = "-TOuuAQ-buE" },
};

pub const npauth_exports = [_]symbols.Export{
    .{ .name = "sceNpAuthPollAsync", .function = trace.wrap("sceNpAuthPollAsync", &services.offline), .expect_id = "gjSyfzSsDcE" },
    .{ .name = "sceNpAuthDeleteRequest", .function = trace.wrap("sceNpAuthDeleteRequest", &services.offline), .expect_id = "H8wG9Bk-nPc" },
    .{ .name = "sceNpAuthCreateAsyncRequest", .function = trace.wrap("sceNpAuthCreateAsyncRequest", &services.offline), .expect_id = "N+mr7GjTvr8" },
    .{ .name = "sceNpAuthGetAuthorizationCodeV3", .function = trace.wrap("sceNpAuthGetAuthorizationCodeV3", &services.offline), .expect_id = "KI4dHLlTNl0" },
    .{ .name = "sceNpAuthGetIdTokenV3", .function = trace.wrap("sceNpAuthGetIdTokenV3", &services.offline), .expect_id = "RdsFVsgSpZY" },
};

pub const npcommerce_exports = [_]symbols.Export{
    .{ .name = "sceNpCommerceDialogUpdateStatus", .function = trace.wrap("sceNpCommerceDialogUpdateStatus", &services.offline), .expect_id = "LR5cwFMMCVE" },
    .{ .name = "sceNpCommerceDialogGetResult", .function = trace.wrap("sceNpCommerceDialogGetResult", &services.offline), .expect_id = "r42bWcQbtZY" },
    .{ .name = "sceNpCommerceDialogTerminate", .function = trace.wrap("sceNpCommerceDialogTerminate", &services.offline), .expect_id = "m-I92Ab50W8" },
    .{ .name = "sceNpCommerceDialogInitialize", .function = trace.wrap("sceNpCommerceDialogInitialize", &services.offline), .expect_id = "0aR2aWmQal4" },
    .{ .name = "sceNpCommerceDialogOpen", .function = trace.wrap("sceNpCommerceDialogOpen", &services.offline), .expect_id = "DfSCDRA3EjY" },
    .{ .name = "sceNpCommerceShowPsStoreIcon", .function = trace.wrap("sceNpCommerceShowPsStoreIcon", &services.offline), .expect_id = "DHmwsa6S8Tc" },
    .{ .name = "sceNpCommerceHidePsStoreIcon", .function = trace.wrap("sceNpCommerceHidePsStoreIcon", &services.offline), .expect_id = "dsqCVsNM0Zg" },
};

pub const npentitlementaccess_exports = [_]symbols.Export{
    .{ .name = "sceNpEntitlementAccessPollUnifiedEntitlementInfoList", .function = trace.wrap("sceNpEntitlementAccessPollUnifiedEntitlementInfoList", &services.offline), .expect_id = "nAEqawEZG5s" },
    .{ .name = "sceNpEntitlementAccessDeleteRequest", .function = trace.wrap("sceNpEntitlementAccessDeleteRequest", &services.offline), .expect_id = "Z0eQj8m7XA8" },
    .{ .name = "sceNpEntitlementAccessPollServiceEntitlementInfoList", .function = trace.wrap("sceNpEntitlementAccessPollServiceEntitlementInfoList", &services.offline), .expect_id = "aFv8qms6XTM" },
    .{ .name = "sceNpEntitlementAccessRequestUnifiedEntitlementInfoList", .function = trace.wrap("sceNpEntitlementAccessRequestUnifiedEntitlementInfoList", &services.offline), .expect_id = "uCZf2L27th8" },
    .{ .name = "sceNpEntitlementAccessRequestServiceEntitlementInfoList", .function = trace.wrap("sceNpEntitlementAccessRequestServiceEntitlementInfoList", &services.offline), .expect_id = "brbRxzr7qyI" },
    .{ .name = "sceNpEntitlementAccessInitialize", .function = trace.wrap("sceNpEntitlementAccessInitialize", &services.npEntitlementAccessInitialize), .expect_id = "jO8DM8oyego" },
};

pub const npgameintent_exports = [_]symbols.Export{
    .{ .name = "sceNpGameIntentTerminate", .function = trace.wrap("sceNpGameIntentTerminate", &services.npGameIntentTerminate), .expect_id = "0HBYxYAjmf0" },
    .{ .name = "sceNpGameIntentInitialize", .function = trace.wrap("sceNpGameIntentInitialize", &services.npGameIntentInitialize), .expect_id = "m87BHxt-H60" },
    .{ .name = "sceNpGameIntentReceiveIntent", .function = trace.wrap("sceNpGameIntentReceiveIntent", &services.npGameIntentReceiveIntent), .expect_id = "jEIXUAr9XE8" },
    .{ .name = "sceNpGameIntentGetPropertyValueString", .function = trace.wrap("sceNpGameIntentGetPropertyValueString", &services.npGameIntentGetPropertyValueString), .expect_id = "rPl0INNc-M8" },
};

pub const npmanager_exports = [_]symbols.Export{
    .{ .name = "sceNpNotifyPremiumFeature", .function = trace.wrap("sceNpNotifyPremiumFeature", &services.offline), .expect_id = "P6piso307SE" },
    // Polling an empty callback queue is a successful no-op. Returning ENOSYS
    // makes Unity's frontend treat normal offline polling as a service fault.
    .{ .name = "sceNpCheckCallback", .function = trace.wrap("sceNpCheckCallback", &services.accept), .expect_id = "3Zl8BePTh9Y" },
    .{ .name = "sceNpCreateRequest", .function = trace.wrap("sceNpCreateRequest", &services.offline), .expect_id = "GpLQDNKICac" },
    .{ .name = "sceNpCheckPremium", .function = trace.wrap("sceNpCheckPremium", &services.offline), .expect_id = "O80NrhUOPGY" },
    .{ .name = "sceNpDeleteRequest", .function = trace.wrap("sceNpDeleteRequest", &services.offline), .expect_id = "S7QTn72PrDw" },
    .{ .name = "sceNpGetUserIdByAccountId", .function = trace.wrap("sceNpGetUserIdByAccountId", &services.offline), .expect_id = "VgYczPGB5ss" },
    .{ .name = "sceNpGetOnlineId", .function = trace.wrap("sceNpGetOnlineId", &services.offline), .expect_id = "XDncXQIJUSk" },
    // Registration itself is local and succeeds on an offline console.  No
    // callback is delivered until the NP state changes, which cannot happen in
    // the emulator's stable offline profile.
    .{ .name = "sceNpRegisterStateCallbackA", .function = trace.wrap("sceNpRegisterStateCallbackA", &services.accept), .expect_id = "qQJfO8HAiaY" },
    .{ .name = "sceNpRegisterNpReachabilityStateCallback", .function = trace.wrap("sceNpRegisterNpReachabilityStateCallback", &services.accept), .expect_id = "hw5KNqAAels" },
    .{ .name = "sceNpCheckNpReachability", .function = trace.wrap("sceNpCheckNpReachability", &services.offline), .expect_id = "KfGZg2y73oM" },
    .{ .name = "sceNpHasSignedUp", .function = trace.wrap("sceNpHasSignedUp", &services.offline), .expect_id = "Oad3rvY-NJQ" },
};

pub const npsessionsignaling_exports = [_]symbols.Export{
    .{ .name = "sceNpSessionSignalingTerminate", .function = trace.wrap("sceNpSessionSignalingTerminate", &services.accept), .expect_id = "CqJuNXo5yiM" },
    .{ .name = "sceNpSessionSignalingInitialize", .function = trace.wrap("sceNpSessionSignalingInitialize", &services.npSessionSignalingInitialize), .expect_id = "ysmw6J-P8Ak" },
    .{ .name = "sceNpSessionSignalingCreateContext2", .function = trace.wrap("sceNpSessionSignalingCreateContext2", &services.offline), .expect_id = "aBuX0PX-T7I" },
    .{ .name = "sceNpSessionSignalingDestroyContext", .function = trace.wrap("sceNpSessionSignalingDestroyContext", &services.offline), .expect_id = "Z9Q9LzQDXf0" },
    .{ .name = "sceNpSessionSignalingDeactivate", .function = trace.wrap("sceNpSessionSignalingDeactivate", &services.offline), .expect_id = "cQkBH-pXhF0" },
    .{ .name = "sceNpSessionSignalingGetConnectionInfo", .function = trace.wrap("sceNpSessionSignalingGetConnectionInfo", &services.offline), .expect_id = "yJw2m6UWDYU" },
    .{ .name = "sceNpSessionSignalingGetConnectionStatus", .function = trace.wrap("sceNpSessionSignalingGetConnectionStatus", &services.offline), .expect_id = "n1fn2KFeLDA" },
    .{ .name = "sceNpSessionSignalingActivateSession", .function = trace.wrap("sceNpSessionSignalingActivateSession", &services.offline), .expect_id = "r4XacqHvkn4" },
};

pub const nptrophy2_exports = [_]symbols.Export{
    .{ .name = "sceNpTrophy2CreateContext", .function = trace.wrap("sceNpTrophy2CreateContext", &services.npTrophy2CreateContext), .expect_id = "Bagshr7OQ6Q" },
    .{ .name = "sceNpTrophy2CreateHandle", .function = trace.wrap("sceNpTrophy2CreateHandle", &services.npTrophy2CreateHandle), .expect_id = "Gz1rmUZpROM" },
    .{ .name = "sceNpTrophy2RegisterContext", .function = trace.wrap("sceNpTrophy2RegisterContext", &services.accept), .expect_id = "bIDov3wBu5Q" },
    .{ .name = "sceNpTrophy2DestroyContext", .function = trace.wrap("sceNpTrophy2DestroyContext", &services.accept), .expect_id = "sysY2FHYff4" },
    .{ .name = "sceNpTrophy2DestroyHandle", .function = trace.wrap("sceNpTrophy2DestroyHandle", &services.accept), .expect_id = "d8P11CI40KE" },
    .{ .name = "sceNpTrophy2GetGameInfo", .function = trace.wrap("sceNpTrophy2GetGameInfo", &services.offline), .expect_id = "4IzqhhUQ3nk" },
    .{ .name = "sceNpTrophy2GetTrophyInfoArray", .function = trace.wrap("sceNpTrophy2GetTrophyInfoArray", &services.offline), .expect_id = "y3zHpdZO6ME" },
    .{ .name = "sceNpTrophy2RegisterUnlockCallback", .function = trace.wrap("sceNpTrophy2RegisterUnlockCallback", &services.accept), .expect_id = "sUXGfNMalIo" },
    .{ .name = "sceNpTrophy2UnregisterUnlockCallback", .function = trace.wrap("sceNpTrophy2UnregisterUnlockCallback", &services.accept), .expect_id = "wVqxM58sIKs" },
};

pub const npuniversaldatasystem_exports = [_]symbols.Export{
    .{ .name = "sceNpUniversalDataSystemRegisterContext", .function = trace.wrap("sceNpUniversalDataSystemRegisterContext", &services.accept), .expect_id = "tpFJ8LIKvPw" },
    .{ .name = "sceNpUniversalDataSystemDestroyHandle", .function = trace.wrap("sceNpUniversalDataSystemDestroyHandle", &services.accept), .expect_id = "AUIHb7jUX3I" },
    .{ .name = "sceNpUniversalDataSystemDestroyContext", .function = trace.wrap("sceNpUniversalDataSystemDestroyContext", &services.accept), .expect_id = "wB7IWzGp2v0" },
    .{ .name = "sceNpUniversalDataSystemPostEvent", .function = trace.wrap("sceNpUniversalDataSystemPostEvent", &services.accept), .expect_id = "CzkKf7ahIyU" },
    .{ .name = "sceNpUniversalDataSystemDestroyEvent", .function = trace.wrap("sceNpUniversalDataSystemDestroyEvent", &services.accept), .expect_id = "wG+84pnNIuo" },
    .{ .name = "sceNpUniversalDataSystemCreateEvent", .function = trace.wrap("sceNpUniversalDataSystemCreateEvent", &services.udsCreateEvent), .expect_id = "p+GcLqwpL9M" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetInt32", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetInt32", &services.accept), .expect_id = "YE4dbtbz6OE" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetUInt32", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetUInt32", &services.accept), .expect_id = "AzD4irAcKE4" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetInt64", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetInt64", &services.accept), .expect_id = "56QLTqx911s" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetUInt64", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetUInt64", &services.accept), .expect_id = "xvsP5Yz6FmY" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetFloat64", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetFloat64", &services.accept), .expect_id = "4Fu8tHW+u-k" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetString", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetString", &services.accept), .expect_id = "MfDb+4Nln64" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetFloat32", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetFloat32", &services.accept), .expect_id = "lbPlT4+QVcE" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetBool", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetBool", &services.accept), .expect_id = "Fidd8vWgyVE" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetArray", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetArray", &services.accept), .expect_id = "Wxbg5x3pTXA" },
    .{ .name = "sceNpUniversalDataSystemDestroyEventPropertyArray", .function = trace.wrap("sceNpUniversalDataSystemDestroyEventPropertyArray", &services.accept), .expect_id = "W-0xwY0ZMjw" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyObjectSetObject", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyObjectSetObject", &services.accept), .expect_id = "74ASEqxSnkM" },
    .{ .name = "sceNpUniversalDataSystemDestroyEventPropertyObject", .function = trace.wrap("sceNpUniversalDataSystemDestroyEventPropertyObject", &services.accept), .expect_id = "kKUH0Viib3c" },
    .{ .name = "sceNpUniversalDataSystemCreateEventPropertyArray", .function = trace.wrap("sceNpUniversalDataSystemCreateEventPropertyArray", &services.accept), .expect_id = "Hm7qubT3b70" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyArraySetBool", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyArraySetBool", &services.accept), .expect_id = "0+l4QSWCM4E" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyArraySetString", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyArraySetString", &services.accept), .expect_id = "4llLk7YJRTE" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyArraySetFloat32", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyArraySetFloat32", &services.accept), .expect_id = "JmgwKm96Lq4" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyArraySetArray", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyArraySetArray", &services.accept), .expect_id = "rdi9BAfDLq8" },
    .{ .name = "sceNpUniversalDataSystemEventPropertyArraySetObject", .function = trace.wrap("sceNpUniversalDataSystemEventPropertyArraySetObject", &services.accept), .expect_id = "XY14n3jNIpE" },
    .{ .name = "sceNpUniversalDataSystemCreateEventPropertyObject", .function = trace.wrap("sceNpUniversalDataSystemCreateEventPropertyObject", &services.accept), .expect_id = "s6W4Zl4Slgk" },
    .{ .name = "sceNpUniversalDataSystemInitialize", .function = trace.wrap("sceNpUniversalDataSystemInitialize", &services.udsInitialize), .expect_id = "sjaobBgqeB4" },
    .{ .name = "sceNpUniversalDataSystemTerminate", .function = trace.wrap("sceNpUniversalDataSystemTerminate", &services.accept), .expect_id = "47UAEuQl+iI" },
    .{ .name = "sceNpUniversalDataSystemCreateContext", .function = trace.wrap("sceNpUniversalDataSystemCreateContext", &services.udsCreateContext), .expect_id = "5zBnau1uIEo" },
    .{ .name = "sceNpUniversalDataSystemCreateHandle", .function = trace.wrap("sceNpUniversalDataSystemCreateHandle", &services.udsCreateHandle), .expect_id = "hT0IAEvN+M0" },
};

pub const npwebapi2_exports = [_]symbols.Export{
    .{ .name = "sceNpWebApi2SetRequestTimeout", .function = trace.wrap("sceNpWebApi2SetRequestTimeout", &services.accept), .expect_id = "TjAutbrkr60" },
    .{ .name = "sceNpWebApi2PushEventCreateFilter", .function = trace.wrap("sceNpWebApi2PushEventCreateFilter", &services.npWebApi2PushEventCreateHandle), .expect_id = "MsaFhR+lPE4" },
    .{ .name = "sceNpWebApi2PushEventDeleteFilter", .function = trace.wrap("sceNpWebApi2PushEventDeleteFilter", &services.accept), .expect_id = "KJdPcOGmK58" },
    .{ .name = "sceNpWebApi2PushEventUnregisterCallback", .function = trace.wrap("sceNpWebApi2PushEventUnregisterCallback", &services.accept), .expect_id = "hOnIlcGrO6g" },
    .{ .name = "sceNpWebApi2PushEventRegisterCallback", .function = trace.wrap("sceNpWebApi2PushEventRegisterCallback", &services.accept), .expect_id = "fY3QqeNkF8k" },
    .{ .name = "sceNpWebApi2PushEventDeletePushContext", .function = trace.wrap("sceNpWebApi2PushEventDeletePushContext", &services.accept), .expect_id = "QafxeZM3WK4" },
    .{ .name = "sceNpWebApi2PushEventUnregisterPushContextCallback", .function = trace.wrap("sceNpWebApi2PushEventUnregisterPushContextCallback", &services.accept), .expect_id = "PmyrbbJSFz0" },
    .{ .name = "sceNpWebApi2PushEventRegisterPushContextCallback", .function = trace.wrap("sceNpWebApi2PushEventRegisterPushContextCallback", &services.accept), .expect_id = "lxtHJMwBsaU" },
    .{ .name = "sceNpWebApi2PushEventCreatePushContext", .function = trace.wrap("sceNpWebApi2PushEventCreatePushContext", &services.npWebApi2PushEventCreateHandle), .expect_id = "NNVf18SlbT8" },
    .{ .name = "sceNpWebApi2PushEventStartPushContextCallback", .function = trace.wrap("sceNpWebApi2PushEventStartPushContextCallback", &services.accept), .expect_id = "AAj9X+4aGYA" },
    .{ .name = "sceNpWebApi2PushEventCreateHandle", .function = trace.wrap("sceNpWebApi2PushEventCreateHandle", &services.npWebApi2PushEventCreateHandle), .expect_id = "WV1GwM32NgY" },
};

pub const pad_exports = [_]symbols.Export{
    .{ .name = "scePadVrControllerReadState", .function = trace.wrap("scePadVrControllerReadState", &services.noDevice), .expect_id = "iA-DdobUen8" },
    .{ .name = "scePadVrControllerGetDeviceInformation", .function = trace.wrap("scePadVrControllerGetDeviceInformation", &services.noDevice), .expect_id = "mbJHDdjhVeY" },
    .{ .name = "scePadVrControllerGetTriggerEffectState", .function = trace.wrap("scePadVrControllerGetTriggerEffectState", &services.noDevice), .expect_id = "OL2CJ2idmhk" },
    .{ .name = "scePadVrControllerSetTriggerEffects", .function = trace.wrap("scePadVrControllerSetTriggerEffects", &services.noDevice), .expect_id = "v8P+9PRqg10" },
    .{ .name = "scePadVrControllerSetTriggerEffect", .function = trace.wrap("scePadVrControllerSetTriggerEffect", &services.noDevice), .expect_id = "6Cdc9bbjrRY" },
    .{ .name = "scePadVrControllerSetVibrationMode", .function = trace.wrap("scePadVrControllerSetVibrationMode", &services.noDevice), .expect_id = "Wf6-PNCyY20" },
    .{ .name = "scePadVrControllerSetVibration", .function = trace.wrap("scePadVrControllerSetVibration", &services.noDevice), .expect_id = "DGCwN1Lmmys" },
    .{ .name = "libScePad:306mCg0ibh8", .function = trace.wrap("libScePad:306mCg0ibh8", &services.accept), .id_override = "306mCg0ibh8" },
};

pub const jpegdec_exports = [_]symbols.Export{
    .{ .name = "sceJpegDecParseHeader", .function = trace.wrap("sceJpegDecParseHeader", &services.accept), .expect_id = "LSinoSQH790" },
    .{ .name = "sceJpegDecQueryMemorySize", .function = trace.wrap("sceJpegDecQueryMemorySize", &services.accept), .expect_id = "uNAUmANZMEw" },
    .{ .name = "sceJpegDecCreate", .function = trace.wrap("sceJpegDecCreate", &services.accept), .expect_id = "JPh3Zgg0Zwc" },
    .{ .name = "sceJpegDecDecode", .function = trace.wrap("sceJpegDecDecode", &services.absent), .expect_id = "1kzQRoWEgSA" },
    .{ .name = "sceJpegDecDelete", .function = trace.wrap("sceJpegDecDelete", &services.accept), .expect_id = "Hwh11+m5KoI" },
};

pub const convert_keycode_exports = [_]symbols.Export{
    .{ .name = "libSceConvertKeycode:mUuUOWI-C+0", .function = trace.wrap("libSceConvertKeycode:mUuUOWI-C+0", &services.accept), .id_override = "mUuUOWI-C+0" },
    .{ .name = "sceConvertKeycodeGetVirtualKeycode", .function = trace.wrap("sceConvertKeycodeGetVirtualKeycode", &services.accept), .expect_id = "vIsoJsLvvlM" },
};

pub const razorcpu_exports = [_]symbols.Export{
    .{ .name = "sceRazorCpuPushMarker", .function = trace.wrap("sceRazorCpuPushMarker", &services.accept), .expect_id = "zw+celG7zSI" },
    .{ .name = "sceRazorCpuPopMarker", .function = trace.wrap("sceRazorCpuPopMarker", &services.accept), .expect_id = "YpkGsMXP3ew" },
    .{ .name = "sceRazorCpuPushMarkerStatic", .function = trace.wrap("sceRazorCpuPushMarkerStatic", &services.accept), .expect_id = "uZrOwuNJX-M" },
};

pub const playgo_exports = [_]symbols.Export{
    .{ .name = "scePlayGoInitialize", .function = trace.wrap("scePlayGoInitialize", &playgo.initialize), .expect_id = "ts6GlZOKRrE" },
    .{ .name = "scePlayGoOpen", .function = trace.wrap("scePlayGoOpen", &playgo.open), .expect_id = "M1Gma1ocrGE" },
    .{ .name = "scePlayGoTerminate", .function = trace.wrap("scePlayGoTerminate", &playgo.terminate), .expect_id = "MPe0EeBGM-E" },
    .{ .name = "scePlayGoClose", .function = trace.wrap("scePlayGoClose", &playgo.close), .expect_id = "Uco1I0dlDi8" },
    .{ .name = "scePlayGoGetLocus", .function = trace.wrap("scePlayGoGetLocus", &playgo.getLocus), .expect_id = "uWIYLFkkwqk" },
    .{ .name = "scePlayGoGetEta", .function = trace.wrap("scePlayGoGetEta", &playgo.getEta), .expect_id = "v6EZ-YWRdMs" },
    .{ .name = "scePlayGoGetProgress", .function = trace.wrap("scePlayGoGetProgress", &playgo.getProgress), .expect_id = "-RJWNMK3fC8" },
    .{ .name = "scePlayGoSetInstallSpeed", .function = trace.wrap("scePlayGoSetInstallSpeed", &playgo.setInstallSpeed), .expect_id = "4AAcTU9R3XM" },
    .{ .name = "scePlayGoPrefetch", .function = trace.wrap("scePlayGoPrefetch", &playgo.prefetch), .expect_id = "-Q1-u1a7p0g" },
    .{ .name = "scePlayGoGetInstallSpeed", .function = trace.wrap("scePlayGoGetInstallSpeed", &playgo.getInstallSpeed), .expect_id = "rvBSfTimejE" },
    .{ .name = "scePlayGoGetLanguageMask", .function = trace.wrap("scePlayGoGetLanguageMask", &playgo.getLanguageMask), .expect_id = "3OMbYZBaa50" },
    .{ .name = "scePlayGoGetToDoList", .function = trace.wrap("scePlayGoGetToDoList", &playgo.getToDoList), .expect_id = "Nn7zKwnA5q0" },
    .{ .name = "scePlayGoSetToDoList", .function = trace.wrap("scePlayGoSetToDoList", &playgo.setToDoList), .expect_id = "gUPGiOQ1tmQ" },
};

pub const playerinvitationdialog_exports = [_]symbols.Export{
    .{ .name = "scePlayerInvitationDialogUpdateStatus", .function = trace.wrap("scePlayerInvitationDialogUpdateStatus", &services.offline), .expect_id = "kFhuwHrIUqs" },
    .{ .name = "scePlayerInvitationDialogTerminate", .function = trace.wrap("scePlayerInvitationDialogTerminate", &services.offline), .expect_id = "gDm5a6GSE94" },
    .{ .name = "scePlayerInvitationDialogInitialize", .function = trace.wrap("scePlayerInvitationDialogInitialize", &services.offline), .expect_id = "JDwx3Bl4bB4" },
    .{ .name = "scePlayerInvitationDialogOpen", .function = trace.wrap("scePlayerInvitationDialogOpen", &services.offline), .expect_id = "rKPTlHwGa4k" },
};

pub const rtc_exports = [_]symbols.Export{
    .{ .name = "sceRtcGetCurrentClockLocalTime", .function = trace.wrap("sceRtcGetCurrentClockLocalTime", &platform_services.rtcGetCurrentClockLocalTime), .expect_id = "ZPD1YOKI+Kw" },
    .{ .name = "sceRtcSetTick", .function = trace.wrap("sceRtcSetTick", &platform_services.rtcSetTick), .expect_id = "ueega6v3GUw" },
    .{ .name = "sceRtcGetTickResolution", .function = trace.wrap("sceRtcGetTickResolution", &platform_services.rtcGetTickResolution), .expect_id = "jMNwqYr4R-k" },
    .{ .name = "sceRtcIsLeapYear", .function = trace.wrap("sceRtcIsLeapYear", &platform_services.rtcIsLeapYear), .expect_id = "Ug8pCwQvh0c" },
    .{ .name = "sceRtcGetDayOfWeek", .function = trace.wrap("sceRtcGetDayOfWeek", &platform_services.rtcGetDayOfWeek), .expect_id = "CyIK-i4XdgQ" },
    .{ .name = "sceRtcGetTick", .function = trace.wrap("sceRtcGetTick", &platform_services.rtcGetTick), .expect_id = "8w-H19ip48I" },
    .{ .name = "sceRtcGetTime_t", .function = trace.wrap("sceRtcGetTime_t", &platform_services.rtcGetTimeT), .expect_id = "BtqmpTRXHgk" },
};

pub const savedatadialog_native_exports = [_]symbols.Export{
    .{ .name = "sceSaveDataDialogTerminate", .function = trace.wrap("sceSaveDataDialogTerminate", &services.absent), .expect_id = "YuH2FA7azqQ" },
    .{ .name = "sceSaveDataDialogOpen", .function = trace.wrap("sceSaveDataDialogOpen", &services.absent), .expect_id = "4tPhsP6FpDI" },
    .{ .name = "sceSaveDataDialogUpdateStatus", .function = trace.wrap("sceSaveDataDialogUpdateStatus", &services.absent), .expect_id = "KK3Bdg1RWK0" },
    .{ .name = "sceSaveDataDialogGetResult", .function = trace.wrap("sceSaveDataDialogGetResult", &services.absent), .expect_id = "yEiJ-qqr6Cg" },
    .{ .name = "sceSaveDataDialogInitialize", .function = trace.wrap("sceSaveDataDialogInitialize", &services.absent), .expect_id = "s9e3+YpRnzw" },
    .{ .name = "sceSaveDataDialogGetStatus", .function = trace.wrap("sceSaveDataDialogGetStatus", &services.saveDataDialogFinished), .expect_id = "ERKzksauAJA" },
    .{ .name = "sceSaveDataDialogIsReadyToDisplay", .function = trace.wrap("sceSaveDataDialogIsReadyToDisplay", &services.saveDataDialogReady), .expect_id = "en7gNVnh878" },
    .{ .name = "sceSaveDataDialogClose", .function = trace.wrap("sceSaveDataDialogClose", &services.accept), .expect_id = "fH46Lag88XY" },
    .{ .name = "sceSaveDataDialogProgressBarInc", .function = trace.wrap("sceSaveDataDialogProgressBarInc", &services.accept), .expect_id = "V-uEeFKARJU" },
    .{ .name = "sceSaveDataDialogProgressBarSetValue", .function = trace.wrap("sceSaveDataDialogProgressBarSetValue", &services.accept), .expect_id = "hay1CfTmLyA" },
};

pub const savedata_native_exports = [_]symbols.Export{
    .{ .name = "sceSaveDataDelete", .function = trace.wrap("sceSaveDataDelete", &services.absent), .expect_id = "S1GkePI17zQ" },
    .{ .name = "sceSaveDataGetMountInfo", .function = trace.wrap("sceSaveDataGetMountInfo", &services.absent), .expect_id = "65VH0Qaaz6s" },
    .{ .name = "sceSaveDataSaveIcon", .function = trace.wrap("sceSaveDataSaveIcon", &services.absent), .expect_id = "c88Yy54Mx0w" },
    .{ .name = "sceSaveDataSetParam", .function = trace.wrap("sceSaveDataSetParam", &services.absent), .expect_id = "85zul--eGXs" },
    .{ .name = "sceSaveDataTerminate", .function = trace.wrap("sceSaveDataTerminate", &services.absent), .expect_id = "yKDy8S5yLA0" },
    .{ .name = "sceSaveDataCreateTransactionResource", .function = trace.wrap("sceSaveDataCreateTransactionResource", &services.absent), .expect_id = "gjRZNnw0JPE" },
    .{ .name = "sceSaveDataMount3", .function = trace.wrap("sceSaveDataMount3", &services.absent), .expect_id = "ZP4e7rlzOUk" },
    .{ .name = "sceSaveDataPrepare", .function = trace.wrap("sceSaveDataPrepare", &services.absent), .expect_id = "sDCBrmc61XU" },
    .{ .name = "sceSaveDataCommit", .function = trace.wrap("sceSaveDataCommit", &services.absent), .expect_id = "ie7qhZ4X0Cc" },
    .{ .name = "sceSaveDataUmount2", .function = trace.wrap("sceSaveDataUmount2", &services.absent), .expect_id = "uW4vfTwMQVo" },
    .{ .name = "sceSaveDataDirNameSearchPs4", .function = trace.wrap("sceSaveDataDirNameSearchPs4", &services.absent), .expect_id = "X4MYzukPc3g" },
    .{ .name = "sceSaveDataTransferringMountPs4", .function = trace.wrap("sceSaveDataTransferringMountPs4", &services.absent), .expect_id = "RjMlsR8EXrw" },
    .{ .name = "sceSaveDataSaveIconByPath", .function = trace.wrap("sceSaveDataSaveIconByPath", &services.absent), .expect_id = "Z7z6HXWORJY" },
    .{ .name = "sceSaveDataBackup", .function = trace.wrap("sceSaveDataBackup", &services.absent), .expect_id = "z1JA8-iJt3k" },
    .{ .name = "sceSaveDataLoadIcon", .function = trace.wrap("sceSaveDataLoadIcon", &services.absent), .expect_id = "cGjO3wM3V28" },
    .{ .name = "sceSaveDataGetEventResult", .function = trace.wrap("sceSaveDataGetEventResult", &services.saveDataNoEvent), .expect_id = "j8xKtiFj0SY" },
    .{ .name = "sceSaveDataDeleteTransactionResource", .function = trace.wrap("sceSaveDataDeleteTransactionResource", &services.accept), .expect_id = "lJUQuaKqoKY" },
};

pub const share_exports = [_]symbols.Export{
    .{ .name = "sceShareFeatureProhibit", .function = trace.wrap("sceShareFeatureProhibit", &services.absent), .expect_id = "5wjxESwX68I" },
    .{ .name = "sceShareInitialize", .function = trace.wrap("sceShareInitialize", &services.absent), .expect_id = "nBDD66kiFW8" },
    .{ .name = "sceShareTerminate", .function = trace.wrap("sceShareTerminate", &services.absent), .expect_id = "0IL1keINExQ" },
    .{ .name = "sceShareFeaturePermit", .function = trace.wrap("sceShareFeaturePermit", &services.absent), .expect_id = "YBiIdcDPrxs" },
};

pub const videoout_exports = [_]symbols.Export{
    // Flip/vblank live in bootstrap_services; only keep the remaining stubs here.
    .{ .name = "sceVideoOutInitializeOutputOptions", .function = trace.wrap("sceVideoOutInitializeOutputOptions", &services.absent), .expect_id = "+I4K03i3EL0" },
    .{ .name = "libSceVideoOut:T0ynQY3mH-0", .function = trace.wrap("libSceVideoOut:T0ynQY3mH-0", &services.accept), .id_override = "T0ynQY3mH-0" },
    .{ .name = "libSceVideoOut:WkYtyOg30do", .function = trace.wrap("libSceVideoOut:WkYtyOg30do", &services.accept), .id_override = "WkYtyOg30do" },
};

pub const voiceqos_exports = [_]symbols.Export{
    .{ .name = "sceVoiceQoSCreateRemoteEndpoint", .function = trace.wrap("sceVoiceQoSCreateRemoteEndpoint", &services.offline), .expect_id = "iqQQW2cBmWU" },
    .{ .name = "sceVoiceQoSDeleteRemoteEndpoint", .function = trace.wrap("sceVoiceQoSDeleteRemoteEndpoint", &services.offline), .expect_id = "H4zqFaDhHW4" },
    .{ .name = "sceVoiceQoSCreateLocalEndpoint", .function = trace.wrap("sceVoiceQoSCreateLocalEndpoint", &services.offline), .expect_id = "lvNClhNHzxI" },
    .{ .name = "sceVoiceQoSConnect", .function = trace.wrap("sceVoiceQoSConnect", &services.offline), .expect_id = "kLU6hhXsa2A" },
    .{ .name = "sceVoiceQoSDeleteLocalEndpoint", .function = trace.wrap("sceVoiceQoSDeleteLocalEndpoint", &services.offline), .expect_id = "kE0kdvcHTiY" },
    .{ .name = "sceVoiceQoSWritePacket", .function = trace.wrap("sceVoiceQoSWritePacket", &services.offline), .expect_id = "SpxLratrO1Q" },
    .{ .name = "sceVoiceQoSGetLocalEndpointAttribute", .function = trace.wrap("sceVoiceQoSGetLocalEndpointAttribute", &services.offline), .expect_id = "eZu2RP0Ma3w" },
    .{ .name = "sceVoiceQoSReadPacket", .function = trace.wrap("sceVoiceQoSReadPacket", &services.offline), .expect_id = "PWokFqab5q4" },
    .{ .name = "sceVoiceQoSSetLocalEndpointAttribute", .function = trace.wrap("sceVoiceQoSSetLocalEndpointAttribute", &services.offline), .expect_id = "F7wS7FbfumQ" },
    .{ .name = "sceVoiceQoSDisconnect", .function = trace.wrap("sceVoiceQoSDisconnect", &services.offline), .expect_id = "j9Xt85krooc" },
    .{ .name = "sceVoiceQoSInit", .function = trace.wrap("sceVoiceQoSInit", &services.offline), .expect_id = "U8IfNl6-Css" },
    .{ .name = "sceVoiceQoSEnd", .function = trace.wrap("sceVoiceQoSEnd", &services.offline), .expect_id = "ATRGkmbolVM" },
};

pub const videodec2_exports = [_]symbols.Export{
    .{ .name = "sceVideodec2ReleaseComputeQueue", .function = trace.wrap("sceVideodec2ReleaseComputeQueue", &services.absent), .expect_id = "UvtA3FAiF4Y" },
    .{ .name = "sceVideodec2Reset", .function = trace.wrap("sceVideodec2Reset", &services.absent), .expect_id = "wJXikG6QFN8" },
    .{ .name = "sceVideodec2DeleteDecoder", .function = trace.wrap("sceVideodec2DeleteDecoder", &services.absent), .expect_id = "jwImxXRGSKA" },
    .{ .name = "sceVideodec2QueryComputeMemoryInfo", .function = trace.wrap("sceVideodec2QueryComputeMemoryInfo", &services.absent), .expect_id = "RnDibcGCPKw" },
    .{ .name = "sceVideodec2AllocateComputeQueue", .function = trace.wrap("sceVideodec2AllocateComputeQueue", &services.absent), .expect_id = "eD+X2SmxUt4" },
    .{ .name = "sceVideodec2Decode", .function = trace.wrap("sceVideodec2Decode", &services.absent), .expect_id = "852F5+q6+iM" },
    .{ .name = "sceVideodec2QueryDecoderMemoryInfo", .function = trace.wrap("sceVideodec2QueryDecoderMemoryInfo", &services.absent), .expect_id = "qqMCwlULR+E" },
    .{ .name = "sceVideodec2GetPictureInfo", .function = trace.wrap("sceVideodec2GetPictureInfo", &services.absent), .expect_id = "NtXRa3dRzU0" },
    .{ .name = "sceVideodec2CreateDecoder", .function = trace.wrap("sceVideodec2CreateDecoder", &services.absent), .expect_id = "CNNRoRYd8XI" },
    .{ .name = "sceVideodec2Flush", .function = trace.wrap("sceVideodec2Flush", &services.absent), .expect_id = "l1hXwscLuCY" },
};

pub const vrtracker2_exports = [_]symbols.Export{
    .{ .name = "sceVrTracker2SetCoordinateSystem", .function = trace.wrap("sceVrTracker2SetCoordinateSystem", &services.noDevice), .expect_id = "UVCMLmS-Eas" },
    .{ .name = "sceVrTracker2GetCoordinateSystem", .function = trace.wrap("sceVrTracker2GetCoordinateSystem", &services.noDevice), .expect_id = "Y-3JCiU9bbU" },
    .{ .name = "sceVrTracker2ResetLocalCoordinate", .function = trace.wrap("sceVrTracker2ResetLocalCoordinate", &services.noDevice), .expect_id = "IdI2f+xHIeA" },
    .{ .name = "sceVrTracker2GetPlayAreaBoundaryGeometry", .function = trace.wrap("sceVrTracker2GetPlayAreaBoundaryGeometry", &services.noDevice), .expect_id = "SCph4ZbkqzU" },
    .{ .name = "sceVrTracker2GetPlayAreaOrientedBoundingBox", .function = trace.wrap("sceVrTracker2GetPlayAreaOrientedBoundingBox", &services.noDevice), .expect_id = "snYs7Nf-RKk" },
    .{ .name = "sceVrTracker2RegisterDevice", .function = trace.wrap("sceVrTracker2RegisterDevice", &services.noDevice), .expect_id = "Dog+g25QYjw" },
    .{ .name = "sceVrTracker2UnregisterDevice", .function = trace.wrap("sceVrTracker2UnregisterDevice", &services.noDevice), .expect_id = "kFt4MB3SUEk" },
    .{ .name = "sceVrTracker2GetResult", .function = trace.wrap("sceVrTracker2GetResult", &services.noDevice), .expect_id = "J4Vh3VVX0iU" },
    .{ .name = "sceVrTracker2LocateCoordinateSystem", .function = trace.wrap("sceVrTracker2LocateCoordinateSystem", &services.noDevice), .expect_id = "f7G97dWnEis" },
    .{ .name = "sceVrTracker2QueryMemory", .function = trace.wrap("sceVrTracker2QueryMemory", &services.noDevice), .expect_id = "TwqZnaIjWv4" },
    .{ .name = "sceVrTracker2Initialize", .function = trace.wrap("sceVrTracker2Initialize", &services.noDevice), .expect_id = "6Jy73SRfG-o" },
    .{ .name = "sceVrTracker2Finalize", .function = trace.wrap("sceVrTracker2Finalize", &services.noDevice), .expect_id = "IQ3UD6SZbXo" },
};

pub const webbrowserdialog_exports = [_]symbols.Export{
    .{ .name = "sceWebBrowserDialogResetCookie", .function = trace.wrap("sceWebBrowserDialogResetCookie", &services.offline), .expect_id = "Cya+jvTtPqg" },
    .{ .name = "sceWebBrowserDialogOpenForPredeterminedContent", .function = trace.wrap("sceWebBrowserDialogOpenForPredeterminedContent", &services.offline), .expect_id = "O7dIZQrwVFY" },
    .{ .name = "sceWebBrowserDialogClose", .function = trace.wrap("sceWebBrowserDialogClose", &services.offline), .expect_id = "PSK+Eik919Q" },
    .{ .name = "sceWebBrowserDialogGetResult", .function = trace.wrap("sceWebBrowserDialogGetResult", &services.offline), .expect_id = "vCaW0fgVQmc" },
    .{ .name = "sceWebBrowserDialogGetStatus", .function = trace.wrap("sceWebBrowserDialogGetStatus", &services.saveDataDialogFinished), .expect_id = "CFTG6a8TjOU" },
};

/// A library, the module that publishes it, and its entry points.
///
/// The two names are kept apart because they routinely differ: a library whose
/// name ends in a version digit usually lives in a module without one, and
/// binding under the wrong module leaves an import that matches on identifier
/// alone -- which the loader rightly refuses, since a bare identifier is no
/// evidence that this is the implementation the caller meant.

// Entry points reached only through the shipped online module, which
// itself is only entered along paths that are refused above. Registered
// so that module links; a title never arrives at them with the network
// answering as it does here.
pub const http_extra_exports = [_]symbols.Export{
    .{ .name = "sceHttpUriEscape", .function = trace.wrap("sceHttpUriEscape", &services.offline), .expect_id = "YuOW3dDAKYc" },
};

pub const json2_extra_exports = [_]symbols.Export{
    .{ .name = "_ZN3sce4Json5Value11referObjectEv", .function = trace.wrap("_ZN3sce4Json5Value11referObjectEv", &services.absent), .expect_id = "-NxEk7XLkDY" },
    .{ .name = "_ZN3sce4Json5Value3setERKNS0_6ObjectE", .function = trace.wrap("_ZN3sce4Json5Value3setERKNS0_6ObjectE", &services.absent), .expect_id = "dFCphqnd+a4" },
    .{ .name = "_ZN3sce4Json5ValueC1El", .function = trace.wrap("_ZN3sce4Json5ValueC1El", &services.absent), .expect_id = "0lLK8+kDqmE" },
    .{ .name = "_ZN3sce4Json5ValueC1ERKNS0_5ArrayE", .function = trace.wrap("_ZN3sce4Json5ValueC1ERKNS0_5ArrayE", &services.absent), .expect_id = "iZeYfOxtMRg" },
    .{ .name = "_ZNK3sce4Json5Value7getRealEv", .function = trace.wrap("_ZNK3sce4Json5Value7getRealEv", &services.absent), .expect_id = "3qrge7L-AU4" },
    .{ .name = "_ZN3sce4Json5ValueC1ERKNS0_6ObjectE", .function = trace.wrap("_ZN3sce4Json5ValueC1ERKNS0_6ObjectE", &services.absent), .expect_id = "3xUXnmUkXfo" },
    .{ .name = "_ZN3sce4Json5ValueC1EPKc", .function = trace.wrap("_ZN3sce4Json5ValueC1EPKc", &services.absent), .expect_id = "b9V6fmppLXY" },
    .{ .name = "_ZNK3sce4Json5Array4backEv", .function = trace.wrap("_ZNK3sce4Json5Array4backEv", &services.absent), .expect_id = "bAM9Qwofus0" },
    .{ .name = "_ZN3sce4Json5ArrayC1Ev", .function = trace.wrap("_ZN3sce4Json5ArrayC1Ev", &services.absent), .expect_id = "JP-PtKMiI1E" },
    .{ .name = "_ZN3sce4Json5ArrayD1Ev", .function = trace.wrap("_ZN3sce4Json5ArrayD1Ev", &services.absent), .expect_id = "HJ8GpRT1aiw" },
    .{ .name = "_ZN3sce4Json6StringaSERKS1_", .function = trace.wrap("_ZN3sce4Json6StringaSERKS1_", &services.absent), .expect_id = "cn9svYGWKDQ" },
    .{ .name = "_ZNK3sce4Json5Value10getIntegerEv", .function = trace.wrap("_ZNK3sce4Json5Value10getIntegerEv", &services.absent), .expect_id = "DIxvoy7Ngvk" },
    .{ .name = "_ZNK3sce4Json6String6lengthEv", .function = trace.wrap("_ZNK3sce4Json6String6lengthEv", &services.absent), .expect_id = "EUH+EmT-v9E" },
    .{ .name = "_ZN3sce4Json5Value3setENS0_9ValueTypeE", .function = trace.wrap("_ZN3sce4Json5Value3setENS0_9ValueTypeE", &services.absent), .expect_id = "IKQimvG9Wqs" },
    .{ .name = "_ZNK3sce4Json5Value9getObjectEv", .function = trace.wrap("_ZNK3sce4Json5Value9getObjectEv", &services.absent), .expect_id = "IlsmvBtMkak" },
    .{ .name = "_ZN3sce4Json5Value10referArrayEv", .function = trace.wrap("_ZN3sce4Json5Value10referArrayEv", &services.absent), .expect_id = "nM5XqdeXFPw" },
    .{ .name = "_ZN3sce4Json6Object5clearEv", .function = trace.wrap("_ZN3sce4Json6Object5clearEv", &services.absent), .expect_id = "oH8aBmLU+fc" },
    .{ .name = "_ZNK3sce4Json5Value8getArrayEv", .function = trace.wrap("_ZNK3sce4Json5Value8getArrayEv", &services.absent), .expect_id = "ONT8As5R1ug" },
    .{ .name = "_ZN3sce4Json6StringC1Ev", .function = trace.wrap("_ZN3sce4Json6StringC1Ev", &services.absent), .expect_id = "qSmqLXXCPas" },
    .{ .name = "_ZN3sce4Json5Value9serializeERNS0_6StringE", .function = trace.wrap("_ZN3sce4Json5Value9serializeERNS0_6StringE", &services.absent), .expect_id = "R7FDWtcN6f8" },
    .{ .name = "_ZNK3sce4Json5Array4sizeEv", .function = trace.wrap("_ZNK3sce4Json5Array4sizeEv", &services.absent), .expect_id = "rQGJeNjOuUk" },
    .{ .name = "_ZNK3sce4Json5Value7getTypeEv", .function = trace.wrap("_ZNK3sce4Json5Value7getTypeEv", &services.absent), .expect_id = "SHtAad20YYM" },
    .{ .name = "_ZN3sce4Json5ValueC1Ed", .function = trace.wrap("_ZN3sce4Json5ValueC1Ed", &services.absent), .expect_id = "sOmU4vnx3s0" },
    .{ .name = "_ZN3sce4Json5ValueC1Eb", .function = trace.wrap("_ZN3sce4Json5ValueC1Eb", &services.absent), .expect_id = "UeuWT+yNdCQ" },
    .{ .name = "_ZN3sce4Json6ObjectaSERKS1_", .function = trace.wrap("_ZN3sce4Json6ObjectaSERKS1_", &services.absent), .expect_id = "urOpESTBZmo" },
    .{ .name = "_ZNK3sce4Json5ValueixEm", .function = trace.wrap("_ZNK3sce4Json5ValueixEm", &services.absent), .expect_id = "XlWbvieLj2M" },
    .{ .name = "_ZN3sce4Json5Array9push_backERKNS0_5ValueE", .function = trace.wrap("_ZN3sce4Json5Array9push_backERKNS0_5ValueE", &services.absent), .expect_id = "zQtLRTqceMY" },
    .{ .name = "_ZNK3sce4Json5Value10getBooleanEv", .function = trace.wrap("_ZNK3sce4Json5Value10getBooleanEv", &services.absent), .expect_id = "zTwZdI8AZ5Y" },
};

pub const npwebapi2_extra_exports = [_]symbols.Export{
    .{ .name = "sceNpWebApi2AbortRequest", .function = trace.wrap("sceNpWebApi2AbortRequest", &services.offline), .expect_id = "zpiPsH7dbFQ" },
};

pub const rtc_extra_exports = [_]symbols.Export{
    .{ .name = "sceRtcParseRFC3339", .function = trace.wrap("sceRtcParseRFC3339", &services.absent), .expect_id = "99bMGglFW3I" },
    .{ .name = "sceRtcFormatRFC3339", .function = trace.wrap("sceRtcFormatRFC3339", &services.absent), .expect_id = "WJ3rqFwymew" },
};

pub const Table = struct { library: []const u8, module: []const u8, exports: []const symbols.Export };

pub const all = [_]Table{
    .{ .library = "libSceAcm", .module = "libSceAcm", .exports = &acm_exports },
    .{ .library = "libSceAgc", .module = "libSceAgc", .exports = &agc_exports },
    .{ .library = "libSceAjm", .module = "libSceAjm", .exports = &ajm_exports },
    .{ .library = "libSceAmpr", .module = "libSceAmpr", .exports = &ampr_exports },
    .{ .library = "libSceAudiodec", .module = "libSceAudiodec", .exports = &audiodec_exports },
    .{ .library = "libSceAudioOut2", .module = "libSceAudioOut", .exports = &audioout2_exports },
    .{ .library = "libSceAvPlayer", .module = "libSceAvPlayer", .exports = &avplayer_exports },
    .{ .library = "libSceCamera2", .module = "libSceCamera", .exports = &camera2_exports },
    .{ .library = "libSceCoredump", .module = "libkernel", .exports = &coredump_exports },
    .{ .library = "libSceErrorDialog", .module = "libSceErrorDialog", .exports = &errordialog_exports },
    .{ .library = "libSceGameLiveStreaming", .module = "libSceGameLiveStreaming", .exports = &gamelivestreaming_exports },
    .{ .library = "libSceGameUpdate", .module = "libSceGameUpdate", .exports = &gameupdate_exports },
    .{ .library = "libSceFont", .module = "libSceFont", .exports = &font.exports },
    .{ .library = "libSceFontFt", .module = "libSceFontFt", .exports = &font.ft_exports },
    .{ .library = "libSceHmd2", .module = "libSceHmd2", .exports = &hmd2_exports },
    .{ .library = "libSceHttp", .module = "libSceHttp", .exports = &http_exports },
    .{ .library = "libSceImeDialog", .module = "libSceImeDialog", .exports = &imedialog_exports },
    .{ .library = "libSceJson2", .module = "libSceJson", .exports = &json2_exports },
    .{ .library = "libSceJpegDec", .module = "libSceJpegDec", .exports = &jpegdec_exports },
    .{ .library = "libSceNet", .module = "libSceNet", .exports = &net_exports },
    .{ .library = "libSceNgs2", .module = "libSceNgs2", .exports = &ngs2_exports },
    .{ .library = "libSceNpAuth", .module = "libSceNpAuth", .exports = &npauth_exports },
    .{ .library = "libSceNpCommerce", .module = "libSceNpCommerce", .exports = &npcommerce_exports },
    .{ .library = "libSceNpEntitlementAccess", .module = "libSceNpEntitlementAccess", .exports = &npentitlementaccess_exports },
    .{ .library = "libSceNpGameIntent", .module = "libSceNpGameIntent", .exports = &npgameintent_exports },
    .{ .library = "libSceNpManager", .module = "libSceNpManager", .exports = &npmanager_exports },
    .{ .library = "libSceNpSessionSignaling", .module = "libSceNpSessionSignaling", .exports = &npsessionsignaling_exports },
    .{ .library = "libSceNpTrophy2", .module = "libSceNpTrophy2", .exports = &nptrophy2_exports },
    .{ .library = "libSceNpUniversalDataSystem", .module = "libSceNpUniversalDataSystem", .exports = &npuniversaldatasystem_exports },
    .{ .library = "libSceNpWebApi2", .module = "libSceNpWebApi2", .exports = &npwebapi2_exports },
    .{ .library = "libScePad", .module = "libScePad", .exports = &pad_exports },
    .{ .library = "libScePlayGo", .module = "libScePlayGo", .exports = &playgo_exports },
    .{ .library = "libScePlayerInvitationDialog", .module = "libScePlayerInvitationDialog", .exports = &playerinvitationdialog_exports },
    .{ .library = "libSceRazorCpu", .module = "libSceRazorCpu", .exports = &razorcpu_exports },
    .{ .library = "libSceRtc", .module = "libSceRtc", .exports = &rtc_exports },
    .{ .library = "libSceSaveDataDialog.native", .module = "libSceSaveDataDialog", .exports = &savedatadialog_native_exports },
    .{ .library = "libSceSaveData_native", .module = "libSceSaveData_native", .exports = &savedata_native_exports },
    .{ .library = "libSceShare", .module = "libSceShare", .exports = &share_exports },
    .{ .library = "libSceVideoOut", .module = "libSceVideoOut", .exports = &videoout_exports },
    .{ .library = "libSceVideodec2", .module = "libSceVideodec2", .exports = &videodec2_exports },
    .{ .library = "libSceVoiceQoS", .module = "libSceVoiceQoS", .exports = &voiceqos_exports },
    .{ .library = "libSceConvertKeycode", .module = "libSceConvertKeycode", .exports = &convert_keycode_exports },
    .{ .library = "libSceVrTracker2", .module = "libSceVrTracker2", .exports = &vrtracker2_exports },
    .{ .library = "libSceWebBrowserDialog", .module = "libSceWebBrowserDialog", .exports = &webbrowserdialog_exports },

    .{ .library = "libSceHttp", .module = "libSceHttp", .exports = &http_extra_exports },
    .{ .library = "libSceJson2", .module = "libSceJson", .exports = &json2_extra_exports },
    .{ .library = "libSceNpWebApi2", .module = "libSceNpWebApi2", .exports = &npwebapi2_extra_exports },
    .{ .library = "libSceRtc", .module = "libSceRtc", .exports = &rtc_extra_exports },
};
