// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Vulkan renderer foundation with optional Win32 presentation.
//!
//! This owns the host instance, device, queue and command pool while exposing
//! the existing API-neutral DCB callback boundary. Supported direct compute
//! work crosses RDNA2 decode, ShaderBindings capture, storage-buffer lowering
//! and SPIR-V pipeline caching. Supported guest vertex/pixel programs cross the
//! real DCB draw callback, render pass, rasterization and image writeback path;
//! an opt-in fixed-shader probe remains for diagnostics. The smoke paths prove
//! queue submission, descriptors, staging, readback and a real
//! surface/swapchain presentation path.

const std = @import("std");
const rdna2 = @import("rdna2");
const builtin = @import("builtin");
const gpu = @import("gpu");
const vk = @import("api.zig");

/// Set to true to enable verbose per-frame GPU debug logging.
/// Disable for performance — each print is a blocking I/O syscall.
const log_verbose_gpu = false;

fn hostTimestampNs() u64 {
    if (comptime builtin.os.tag != .windows) return 0;
    var counter: std.os.windows.LARGE_INTEGER = 0;
    var frequency: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or
        !std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or
        counter < 0 or frequency <= 0)
    {
        return 0;
    }
    const scaled = @as(u128, @intCast(counter)) * std.time.ns_per_s;
    return @intCast(scaled / @as(u128, @intCast(frequency)));
}

fn elapsedHostNanoseconds(started: u64) u64 {
    const finished = hostTimestampNs();
    if (started == 0 or finished < started) return 0;
    return finished - started;
}

pub const Error = error{
    VulkanLoaderNotFound,
    MissingVulkanFunction,
    VulkanVersionTooOld,
    InstanceCreationFailed,
    NoPhysicalDevice,
    NoCompatiblePhysicalDevice,
    DeviceCreationFailed,
    QueueUnavailable,
    CommandPoolCreationFailed,
    CommandBufferAllocationFailed,
    CommandBufferResetFailed,
    CommandBufferBeginFailed,
    CommandBufferEndFailed,
    BufferCreationFailed,
    NoCompatibleMemoryType,
    MemoryAllocationFailed,
    MemoryBindingFailed,
    MemoryMapFailed,
    ShaderModuleCreationFailed,
    PipelineCacheCreationFailed,
    PipelineLayoutCreationFailed,
    ComputePipelineCreationFailed,
    GraphicsPipelineCreationFailed,
    ImageCreationFailed,
    ImageViewCreationFailed,
    RenderPassCreationFailed,
    FramebufferCreationFailed,
    DescriptorSetLayoutCreationFailed,
    DescriptorPoolCreationFailed,
    DescriptorSetAllocationFailed,
    FenceCreationFailed,
    FenceResetFailed,
    QueueSubmissionFailed,
    FenceWaitFailed,
    DeviceWaitFailed,
    ReadbackMismatch,
    GuestMemoryUnavailable,
    GuestMemoryReadFailed,
    GuestMemoryWriteFailed,
    GuestBufferTooLarge,
    GuestBufferCacheFull,
    GuestBufferNotStaged,
    InvalidStorageDescriptor,
    MissingStorageDescriptor,
    ComputePipelineCacheFull,
    GraphicsPipelineCacheFull,
    MissingComputeProgram,
    MissingGraphicsProgram,
    InvalidDispatchPacket,
    UnsupportedIndirectDispatch,
    UnsupportedDrawPacket,
    UnsupportedReleaseDataSelection,
    GraphicsProbeReadbackMismatch,
    MissingColorTarget,
    UnsupportedColorTarget,
    RenderTargetCacheFull,
    UnsupportedGraphicsState,
    MissingPresentedFrame,
    PresentationRejected,
    UnsupportedSampledImage,
    UnsupportedStorageImage,
    SamplerCreationFailed,
    UnsupportedPresentationPlatform,
    SurfaceCreationFailed,
    SurfaceQueryFailed,
    SurfaceFormatUnavailable,
    SwapchainCreationFailed,
    SwapchainImageQueryFailed,
    SwapchainAcquireFailed,
    SwapchainPresentFailed,
};

pub const NativeWindow = struct {
    instance: *anyopaque,
    window: *anyopaque,
    width: u32,
    height: u32,
};

pub const Options = struct {
    enable_validation: bool = builtin.mode == .Debug,
    /// Diagnostic-only fixed shaders used to prove the DCB graphics submission
    /// and color-target path before guest vertex/pixel lowering is connected.
    enable_graphics_probe: bool = false,
    /// One-shot diagnostic readback after the first guest graphics draw.
    /// Disabled by default because a 4K target costs roughly 32 MiB of PCIe
    /// traffic and a queue synchronization.
    capture_first_graphics_frame: bool = false,
    /// Replaces translated guest pixel shaders with an opaque diagnostic
    /// colour while retaining the guest target and pipeline state.
    force_probe_fragment: bool = false,
    /// Replaces a guest pixel shader with a minimal sample from its first T#/S#
    /// binding. This separates texture staging/sampling from guest PS ALU.
    force_probe_fragment_texture: bool = false,
    /// Displays PARAM0 directly, separating vertex export/interpolation from
    /// fragment texture sampling and ALU.
    force_probe_fragment_parameter: bool = false,
    /// Samples with PARAM1.xy and multiplies by PARAM0. This mirrors the common
    /// Unity UI pixel path while omitting its constant-buffer and packed-export
    /// tail, making those two halves independently diagnosable.
    force_probe_fragment_ui: bool = false,
    /// Diagnostic fast path for graphics bring-up. Command processing and
    /// draws continue, but guest compute dispatches are not submitted.
    skip_compute_dispatches: bool = false,
    /// Translates guest compute programs and prepares their resources without
    /// submitting them to Vulkan. This isolates translation and binding gaps
    /// from GPU execution faults while preserving later command processing.
    translate_compute_only: bool = false,
    /// Optional Win32 output window. Supplying it enables the required surface
    /// and swapchain extensions and constrains device selection to a queue that
    /// can present to this exact surface.
    native_window: ?NativeWindow = null,
};

pub const graphics_probe_width: u32 = 64;
pub const graphics_probe_height: u32 = 64;
pub const graphics_probe_bytes: usize = graphics_probe_width * graphics_probe_height * 4;

pub const DeviceInfo = struct {
    name_bytes: [256]u8 = [_]u8{0} ** 256,
    name_length: u16 = 0,
    api_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: u32,

    pub fn name(self: *const DeviceInfo) []const u8 {
        return self.name_bytes[0..self.name_length];
    }
};

pub const SmokeReport = struct {
    bytes_copied: usize,
    compute_dispatches: u32,
    queue_family_index: u32,
};

pub const PresentedFrame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    row_pitch_bytes: u32,
    guest_address: u64,
    flip: gpu.state.Flip,
};

pub const PresentationSink = struct {
    context: ?*anyopaque,
    present: *const fn (?*anyopaque, PresentedFrame) bool,
};

/// Receives the rolling guest flip rate in tenths of a frame per second.
/// Keeping this callback API-neutral lets the Win32 window own its title while
/// the renderer remains usable by headless and non-Windows tools.
pub const FrameRateSink = struct {
    context: ?*anyopaque,
    update: *const fn (?*anyopaque, u32) void,
};

pub const FrameRateCounter = struct {
    started_ns: u64 = 0,
    frames: u64 = 0,

    pub fn note(self: *FrameRateCounter, now_ns: u64) ?u32 {
        if (now_ns == 0) return null;
        if (self.started_ns == 0 or now_ns < self.started_ns) {
            self.started_ns = now_ns;
            self.frames = 0;
            return null;
        }
        self.frames +|= 1;
        const elapsed_ns = now_ns - self.started_ns;
        if (elapsed_ns < std.time.ns_per_s) return null;

        const scaled = @as(u128, self.frames) * 10 * std.time.ns_per_s / elapsed_ns;
        const fps_tenths: u32 = @intCast(@min(scaled, std.math.maxInt(u32)));
        self.started_ns = now_ns;
        self.frames = 0;
        return fps_tenths;
    }
};

/// A display buffer a flip names, as the display side describes it.
///
/// The geometry travels with the address because a flip can name a buffer this
/// renderer has never drawn into, and showing that buffer means reading it —
/// which cannot be done without knowing its shape.
pub const DisplayBuffer = struct {
    address: u64,
    width: u32,
    height: u32,
    pitch_in_pixels: u32,
    /// SceVideoOutTilingMode: 0 is the display-tiled layout, 1 is linear.
    tiling_mode: u32 = 0,
};

pub const DisplayBufferResolver = struct {
    context: ?*anyopaque,
    resolve: *const fn (?*anyopaque, gpu.state.Flip) ?DisplayBuffer,
};

pub const StagedBuffer = struct {
    buffer: vk.Buffer,
    descriptor_set: vk.DescriptorSet,
    descriptor_index: u32,
    size: vk.DeviceSize,
    allocation_cache_hit: bool,
};

pub const DispatchReport = struct {
    pipeline_cache_hit: bool,
    group_count: [3]u32,
    spirv_words: usize,
};

pub const GuestMemory = struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, []u8) bool,
    write: *const fn (?*anyopaque, u64, []const u8) bool,
    /// Optional AGC registry lookup. A renderer embedding can expose relocated
    /// shader headers without coupling the API-neutral GPU module back to HLE.
    shader_header: ?*const fn (?*anyopaque, u64) ?u64 = null,
};

const WindowsLibrary = struct {
    handle: *anyopaque,

    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

    fn open(name: [:0]const u8) !WindowsLibrary {
        return .{ .handle = LoadLibraryA(name) orelse return error.FileNotFound };
    }

    fn close(self: *WindowsLibrary) void {
        _ = FreeLibrary(self.handle);
    }

    fn lookup(self: *WindowsLibrary, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.handle, name) orelse return null);
    }
};

const NativeLibrary = if (builtin.os.tag == .windows) WindowsLibrary else std.DynLib;

const Loader = struct {
    library: NativeLibrary,
    get_instance_proc_addr: vk.PfnGetInstanceProcAddr,

    fn init() Error!Loader {
        const names: []const [:0]const u8 = switch (builtin.os.tag) {
            .windows => &.{"vulkan-1.dll"},
            .linux => &.{ "libvulkan.so.1", "libvulkan.so" },
            .macos => &.{ "libvulkan.1.dylib", "libvulkan.dylib" },
            else => &.{},
        };
        for (names) |name| {
            var library = NativeLibrary.open(name) catch continue;
            const get_proc = library.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
                library.close();
                continue;
            };
            return .{ .library = library, .get_instance_proc_addr = get_proc };
        }
        return Error.VulkanLoaderNotFound;
    }

    fn deinit(self: *Loader) void {
        self.library.close();
    }

    fn global(self: *const Loader, comptime T: type, name: [*:0]const u8) Error!T {
        const address = self.get_instance_proc_addr(null, name) orelse return Error.MissingVulkanFunction;
        return @ptrCast(address);
    }

    fn instance(self: *const Loader, instance_handle: vk.Instance, comptime T: type, name: [*:0]const u8) Error!T {
        const address = self.get_instance_proc_addr(instance_handle, name) orelse return Error.MissingVulkanFunction;
        return @ptrCast(address);
    }
};

const InstanceFunctions = struct {
    destroy_instance: vk.PfnDestroyInstance,
    enumerate_physical_devices: vk.PfnEnumeratePhysicalDevices,
    get_physical_device_properties: vk.PfnGetPhysicalDeviceProperties,
    get_queue_family_properties: vk.PfnGetPhysicalDeviceQueueFamilyProperties,
    get_memory_properties: vk.PfnGetPhysicalDeviceMemoryProperties,
    create_device: vk.PfnCreateDevice,
    get_device_proc_addr: vk.PfnGetDeviceProcAddr,

    fn load(loader: *const Loader, instance_handle: vk.Instance) Error!InstanceFunctions {
        return .{
            .destroy_instance = try loader.instance(instance_handle, vk.PfnDestroyInstance, "vkDestroyInstance"),
            .enumerate_physical_devices = try loader.instance(instance_handle, vk.PfnEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices"),
            .get_physical_device_properties = try loader.instance(instance_handle, vk.PfnGetPhysicalDeviceProperties, "vkGetPhysicalDeviceProperties"),
            .get_queue_family_properties = try loader.instance(instance_handle, vk.PfnGetPhysicalDeviceQueueFamilyProperties, "vkGetPhysicalDeviceQueueFamilyProperties"),
            .get_memory_properties = try loader.instance(instance_handle, vk.PfnGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties"),
            .create_device = try loader.instance(instance_handle, vk.PfnCreateDevice, "vkCreateDevice"),
            .get_device_proc_addr = try loader.instance(instance_handle, vk.PfnGetDeviceProcAddr, "vkGetDeviceProcAddr"),
        };
    }
};

const SurfaceFunctions = struct {
    create_win32_surface: vk.PfnCreateWin32SurfaceKHR,
    destroy_surface: vk.PfnDestroySurfaceKHR,
    get_surface_support: vk.PfnGetPhysicalDeviceSurfaceSupportKHR,
    get_surface_capabilities: vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR,
    get_surface_formats: vk.PfnGetPhysicalDeviceSurfaceFormatsKHR,

    fn load(loader: *const Loader, instance_handle: vk.Instance) Error!SurfaceFunctions {
        if (builtin.os.tag != .windows) return Error.UnsupportedPresentationPlatform;
        return .{
            .create_win32_surface = try loader.instance(instance_handle, vk.PfnCreateWin32SurfaceKHR, "vkCreateWin32SurfaceKHR"),
            .destroy_surface = try loader.instance(instance_handle, vk.PfnDestroySurfaceKHR, "vkDestroySurfaceKHR"),
            .get_surface_support = try loader.instance(instance_handle, vk.PfnGetPhysicalDeviceSurfaceSupportKHR, "vkGetPhysicalDeviceSurfaceSupportKHR"),
            .get_surface_capabilities = try loader.instance(instance_handle, vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"),
            .get_surface_formats = try loader.instance(instance_handle, vk.PfnGetPhysicalDeviceSurfaceFormatsKHR, "vkGetPhysicalDeviceSurfaceFormatsKHR"),
        };
    }
};

const DeviceFunctions = struct {
    destroy_device: vk.PfnDestroyDevice,
    get_device_queue: vk.PfnGetDeviceQueue,
    device_wait_idle: vk.PfnDeviceWaitIdle,
    create_command_pool: vk.PfnCreateCommandPool,
    destroy_command_pool: vk.PfnDestroyCommandPool,
    allocate_command_buffers: vk.PfnAllocateCommandBuffers,
    free_command_buffers: vk.PfnFreeCommandBuffers,
    reset_command_buffer: vk.PfnResetCommandBuffer,
    begin_command_buffer: vk.PfnBeginCommandBuffer,
    end_command_buffer: vk.PfnEndCommandBuffer,
    queue_submit: vk.PfnQueueSubmit,
    create_fence: vk.PfnCreateFence,
    destroy_fence: vk.PfnDestroyFence,
    wait_for_fences: vk.PfnWaitForFences,
    reset_fences: vk.PfnResetFences,
    create_buffer: vk.PfnCreateBuffer,
    destroy_buffer: vk.PfnDestroyBuffer,
    get_buffer_memory_requirements: vk.PfnGetBufferMemoryRequirements,
    allocate_memory: vk.PfnAllocateMemory,
    free_memory: vk.PfnFreeMemory,
    bind_buffer_memory: vk.PfnBindBufferMemory,
    create_image: vk.PfnCreateImage,
    destroy_image: vk.PfnDestroyImage,
    get_image_memory_requirements: vk.PfnGetImageMemoryRequirements,
    bind_image_memory: vk.PfnBindImageMemory,
    create_image_view: vk.PfnCreateImageView,
    destroy_image_view: vk.PfnDestroyImageView,
    create_sampler: vk.PfnCreateSampler,
    destroy_sampler: vk.PfnDestroySampler,
    map_memory: vk.PfnMapMemory,
    unmap_memory: vk.PfnUnmapMemory,
    create_shader_module: vk.PfnCreateShaderModule,
    destroy_shader_module: vk.PfnDestroyShaderModule,
    create_pipeline_cache: vk.PfnCreatePipelineCache,
    destroy_pipeline_cache: vk.PfnDestroyPipelineCache,
    get_pipeline_cache_data: vk.PfnGetPipelineCacheData,
    create_descriptor_set_layout: vk.PfnCreateDescriptorSetLayout,
    destroy_descriptor_set_layout: vk.PfnDestroyDescriptorSetLayout,
    create_descriptor_pool: vk.PfnCreateDescriptorPool,
    destroy_descriptor_pool: vk.PfnDestroyDescriptorPool,
    allocate_descriptor_sets: vk.PfnAllocateDescriptorSets,
    update_descriptor_sets: vk.PfnUpdateDescriptorSets,
    create_pipeline_layout: vk.PfnCreatePipelineLayout,
    destroy_pipeline_layout: vk.PfnDestroyPipelineLayout,
    create_compute_pipelines: vk.PfnCreateComputePipelines,
    create_graphics_pipelines: vk.PfnCreateGraphicsPipelines,
    create_render_pass: vk.PfnCreateRenderPass,
    destroy_render_pass: vk.PfnDestroyRenderPass,
    create_framebuffer: vk.PfnCreateFramebuffer,
    destroy_framebuffer: vk.PfnDestroyFramebuffer,
    destroy_pipeline: vk.PfnDestroyPipeline,
    cmd_bind_pipeline: vk.PfnCmdBindPipeline,
    cmd_bind_descriptor_sets: vk.PfnCmdBindDescriptorSets,
    cmd_dispatch: vk.PfnCmdDispatch,
    cmd_begin_render_pass: vk.PfnCmdBeginRenderPass,
    cmd_end_render_pass: vk.PfnCmdEndRenderPass,
    cmd_draw: vk.PfnCmdDraw,
    cmd_draw_indexed: vk.PfnCmdDrawIndexed,
    cmd_bind_index_buffer: vk.PfnCmdBindIndexBuffer,
    cmd_clear_color_image: vk.PfnCmdClearColorImage,
    cmd_clear_depth_stencil_image: vk.PfnCmdClearDepthStencilImage,
    cmd_copy_buffer: vk.PfnCmdCopyBuffer,
    cmd_copy_image_to_buffer: vk.PfnCmdCopyImageToBuffer,
    cmd_copy_buffer_to_image: vk.PfnCmdCopyBufferToImage,
    cmd_blit_image: vk.PfnCmdBlitImage,
    cmd_pipeline_barrier: vk.PfnCmdPipelineBarrier,

    fn load(get_proc: vk.PfnGetDeviceProcAddr, device: vk.Device) Error!DeviceFunctions {
        return .{
            .destroy_device = try deviceProc(get_proc, device, vk.PfnDestroyDevice, "vkDestroyDevice"),
            .get_device_queue = try deviceProc(get_proc, device, vk.PfnGetDeviceQueue, "vkGetDeviceQueue"),
            .device_wait_idle = try deviceProc(get_proc, device, vk.PfnDeviceWaitIdle, "vkDeviceWaitIdle"),
            .create_command_pool = try deviceProc(get_proc, device, vk.PfnCreateCommandPool, "vkCreateCommandPool"),
            .destroy_command_pool = try deviceProc(get_proc, device, vk.PfnDestroyCommandPool, "vkDestroyCommandPool"),
            .allocate_command_buffers = try deviceProc(get_proc, device, vk.PfnAllocateCommandBuffers, "vkAllocateCommandBuffers"),
            .free_command_buffers = try deviceProc(get_proc, device, vk.PfnFreeCommandBuffers, "vkFreeCommandBuffers"),
            .reset_command_buffer = try deviceProc(get_proc, device, vk.PfnResetCommandBuffer, "vkResetCommandBuffer"),
            .begin_command_buffer = try deviceProc(get_proc, device, vk.PfnBeginCommandBuffer, "vkBeginCommandBuffer"),
            .end_command_buffer = try deviceProc(get_proc, device, vk.PfnEndCommandBuffer, "vkEndCommandBuffer"),
            .queue_submit = try deviceProc(get_proc, device, vk.PfnQueueSubmit, "vkQueueSubmit"),
            .create_fence = try deviceProc(get_proc, device, vk.PfnCreateFence, "vkCreateFence"),
            .destroy_fence = try deviceProc(get_proc, device, vk.PfnDestroyFence, "vkDestroyFence"),
            .wait_for_fences = try deviceProc(get_proc, device, vk.PfnWaitForFences, "vkWaitForFences"),
            .reset_fences = try deviceProc(get_proc, device, vk.PfnResetFences, "vkResetFences"),
            .create_buffer = try deviceProc(get_proc, device, vk.PfnCreateBuffer, "vkCreateBuffer"),
            .destroy_buffer = try deviceProc(get_proc, device, vk.PfnDestroyBuffer, "vkDestroyBuffer"),
            .get_buffer_memory_requirements = try deviceProc(get_proc, device, vk.PfnGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements"),
            .allocate_memory = try deviceProc(get_proc, device, vk.PfnAllocateMemory, "vkAllocateMemory"),
            .free_memory = try deviceProc(get_proc, device, vk.PfnFreeMemory, "vkFreeMemory"),
            .bind_buffer_memory = try deviceProc(get_proc, device, vk.PfnBindBufferMemory, "vkBindBufferMemory"),
            .create_image = try deviceProc(get_proc, device, vk.PfnCreateImage, "vkCreateImage"),
            .destroy_image = try deviceProc(get_proc, device, vk.PfnDestroyImage, "vkDestroyImage"),
            .get_image_memory_requirements = try deviceProc(get_proc, device, vk.PfnGetImageMemoryRequirements, "vkGetImageMemoryRequirements"),
            .bind_image_memory = try deviceProc(get_proc, device, vk.PfnBindImageMemory, "vkBindImageMemory"),
            .create_image_view = try deviceProc(get_proc, device, vk.PfnCreateImageView, "vkCreateImageView"),
            .destroy_image_view = try deviceProc(get_proc, device, vk.PfnDestroyImageView, "vkDestroyImageView"),
            .create_sampler = try deviceProc(get_proc, device, vk.PfnCreateSampler, "vkCreateSampler"),
            .destroy_sampler = try deviceProc(get_proc, device, vk.PfnDestroySampler, "vkDestroySampler"),
            .map_memory = try deviceProc(get_proc, device, vk.PfnMapMemory, "vkMapMemory"),
            .unmap_memory = try deviceProc(get_proc, device, vk.PfnUnmapMemory, "vkUnmapMemory"),
            .create_shader_module = try deviceProc(get_proc, device, vk.PfnCreateShaderModule, "vkCreateShaderModule"),
            .destroy_shader_module = try deviceProc(get_proc, device, vk.PfnDestroyShaderModule, "vkDestroyShaderModule"),
            .create_pipeline_cache = try deviceProc(get_proc, device, vk.PfnCreatePipelineCache, "vkCreatePipelineCache"),
            .destroy_pipeline_cache = try deviceProc(get_proc, device, vk.PfnDestroyPipelineCache, "vkDestroyPipelineCache"),
            .get_pipeline_cache_data = try deviceProc(get_proc, device, vk.PfnGetPipelineCacheData, "vkGetPipelineCacheData"),
            .create_descriptor_set_layout = try deviceProc(get_proc, device, vk.PfnCreateDescriptorSetLayout, "vkCreateDescriptorSetLayout"),
            .destroy_descriptor_set_layout = try deviceProc(get_proc, device, vk.PfnDestroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout"),
            .create_descriptor_pool = try deviceProc(get_proc, device, vk.PfnCreateDescriptorPool, "vkCreateDescriptorPool"),
            .destroy_descriptor_pool = try deviceProc(get_proc, device, vk.PfnDestroyDescriptorPool, "vkDestroyDescriptorPool"),
            .allocate_descriptor_sets = try deviceProc(get_proc, device, vk.PfnAllocateDescriptorSets, "vkAllocateDescriptorSets"),
            .update_descriptor_sets = try deviceProc(get_proc, device, vk.PfnUpdateDescriptorSets, "vkUpdateDescriptorSets"),
            .create_pipeline_layout = try deviceProc(get_proc, device, vk.PfnCreatePipelineLayout, "vkCreatePipelineLayout"),
            .destroy_pipeline_layout = try deviceProc(get_proc, device, vk.PfnDestroyPipelineLayout, "vkDestroyPipelineLayout"),
            .create_compute_pipelines = try deviceProc(get_proc, device, vk.PfnCreateComputePipelines, "vkCreateComputePipelines"),
            .create_graphics_pipelines = try deviceProc(get_proc, device, vk.PfnCreateGraphicsPipelines, "vkCreateGraphicsPipelines"),
            .create_render_pass = try deviceProc(get_proc, device, vk.PfnCreateRenderPass, "vkCreateRenderPass"),
            .destroy_render_pass = try deviceProc(get_proc, device, vk.PfnDestroyRenderPass, "vkDestroyRenderPass"),
            .create_framebuffer = try deviceProc(get_proc, device, vk.PfnCreateFramebuffer, "vkCreateFramebuffer"),
            .destroy_framebuffer = try deviceProc(get_proc, device, vk.PfnDestroyFramebuffer, "vkDestroyFramebuffer"),
            .destroy_pipeline = try deviceProc(get_proc, device, vk.PfnDestroyPipeline, "vkDestroyPipeline"),
            .cmd_bind_pipeline = try deviceProc(get_proc, device, vk.PfnCmdBindPipeline, "vkCmdBindPipeline"),
            .cmd_bind_descriptor_sets = try deviceProc(get_proc, device, vk.PfnCmdBindDescriptorSets, "vkCmdBindDescriptorSets"),
            .cmd_dispatch = try deviceProc(get_proc, device, vk.PfnCmdDispatch, "vkCmdDispatch"),
            .cmd_begin_render_pass = try deviceProc(get_proc, device, vk.PfnCmdBeginRenderPass, "vkCmdBeginRenderPass"),
            .cmd_end_render_pass = try deviceProc(get_proc, device, vk.PfnCmdEndRenderPass, "vkCmdEndRenderPass"),
            .cmd_draw = try deviceProc(get_proc, device, vk.PfnCmdDraw, "vkCmdDraw"),
            .cmd_draw_indexed = try deviceProc(get_proc, device, vk.PfnCmdDrawIndexed, "vkCmdDrawIndexed"),
            .cmd_bind_index_buffer = try deviceProc(get_proc, device, vk.PfnCmdBindIndexBuffer, "vkCmdBindIndexBuffer"),
            .cmd_clear_color_image = try deviceProc(get_proc, device, vk.PfnCmdClearColorImage, "vkCmdClearColorImage"),
            .cmd_clear_depth_stencil_image = try deviceProc(get_proc, device, vk.PfnCmdClearDepthStencilImage, "vkCmdClearDepthStencilImage"),
            .cmd_copy_buffer = try deviceProc(get_proc, device, vk.PfnCmdCopyBuffer, "vkCmdCopyBuffer"),
            .cmd_copy_image_to_buffer = try deviceProc(get_proc, device, vk.PfnCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer"),
            .cmd_copy_buffer_to_image = try deviceProc(get_proc, device, vk.PfnCmdCopyBufferToImage, "vkCmdCopyBufferToImage"),
            .cmd_blit_image = try deviceProc(get_proc, device, vk.PfnCmdBlitImage, "vkCmdBlitImage"),
            .cmd_pipeline_barrier = try deviceProc(get_proc, device, vk.PfnCmdPipelineBarrier, "vkCmdPipelineBarrier"),
        };
    }
};

const SwapchainFunctions = struct {
    create_swapchain: vk.PfnCreateSwapchainKHR,
    destroy_swapchain: vk.PfnDestroySwapchainKHR,
    get_swapchain_images: vk.PfnGetSwapchainImagesKHR,
    acquire_next_image: vk.PfnAcquireNextImageKHR,
    queue_present: vk.PfnQueuePresentKHR,

    fn load(get_proc: vk.PfnGetDeviceProcAddr, device: vk.Device) Error!SwapchainFunctions {
        return .{
            .create_swapchain = try deviceProc(get_proc, device, vk.PfnCreateSwapchainKHR, "vkCreateSwapchainKHR"),
            .destroy_swapchain = try deviceProc(get_proc, device, vk.PfnDestroySwapchainKHR, "vkDestroySwapchainKHR"),
            .get_swapchain_images = try deviceProc(get_proc, device, vk.PfnGetSwapchainImagesKHR, "vkGetSwapchainImagesKHR"),
            .acquire_next_image = try deviceProc(get_proc, device, vk.PfnAcquireNextImageKHR, "vkAcquireNextImageKHR"),
            .queue_present = try deviceProc(get_proc, device, vk.PfnQueuePresentKHR, "vkQueuePresentKHR"),
        };
    }
};

fn deviceProc(get_proc: vk.PfnGetDeviceProcAddr, device: vk.Device, comptime T: type, name: [*:0]const u8) Error!T {
    const address = get_proc(device, name) orelse return Error.MissingVulkanFunction;
    return @ptrCast(address);
}

const Candidate = struct {
    physical_device: vk.PhysicalDevice,
    queue_family_index: u32,
    info: DeviceInfo,
    score: u32,
};

const OwnedBuffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
};

const OwnedImage = struct {
    handle: vk.Image,
    memory: vk.DeviceMemory,
};

// Guest vertex/constant ranges are highly transient. A bounded LRU avoids
// keeping hundreds of individual Vulkan allocations alive after the title has
// moved its ring buffers on, while still covering every descriptor in a draw.
const maximum_guest_buffers = maximum_storage_descriptors;
pub const maximum_storage_descriptors = 64;
const maximum_storage_images = 8;
const dynamic_scalar_descriptor_binding = 2 + maximum_storage_images;
const sampled_image_3d_descriptor_binding = dynamic_scalar_descriptor_binding + 1;
const dynamic_scalar_words_per_stage = gpu.scalar_provenance.maximum_scalar_specializations;
const dynamic_scalar_buffer_words = dynamic_scalar_words_per_stage * 2;
const dynamic_scalar_buffer_bytes = dynamic_scalar_buffer_words * @sizeOf(u32);
const maximum_storage_mappings = 1024;
/// Modern Unity titles specialize hundreds of compute kernels during scene
/// bootstrap. Keep those pipelines resident instead of stopping the DCB queue
/// as soon as the initial 256-entry bring-up bound is reached.
const maximum_compute_pipelines = 2048;
/// Titles that specialize transform and colour constants reach thousands of
/// shader variants in seconds: Terminator 2D passes six thousand within a
/// minute of play. At 256 the cache recycled entries the next frame needed and
/// every draw paid a driver compile. The bound stays large until those
/// constants stop being specialized, at which point a title needs one pipeline
/// per program and this can come back down.
const maximum_graphics_pipelines = 8192;
/// Distinct guest shader programs kept in decoded form.
const maximum_analyzed_programs = 512;
/// Longest program the decoder will walk before giving up on it.
const maximum_shader_instructions = 4096;
const maximum_staged_buffer_bytes = 128 * 1024 * 1024;
/// Large compute outputs are overwhelmingly GPU-only working sets. Reading
/// them over PCIe after every dispatch serializes work that remains resident
/// on the console; keep those allocations authoritative until an actual guest
/// or resource read needs their bytes.
const deferred_storage_write_min_bytes = 1024 * 1024;
const maximum_frame_bytes = 128 * 1024 * 1024;
const maximum_completed_frames = 16;
const maximum_render_targets = 16;
const maximum_depth_targets = 16;
const maximum_sampled_images = 32;
/// One DCC key byte covers this many bytes of the compressed colour surface.
const dcc_block_bytes = 256;
/// Bounds the key read for a fast-clear probe; covers surfaces up to 1 GiB.
const maximum_dcc_key_bytes = 4 * 1024 * 1024;
/// CMASK is one nibble per 8x8 pixel region; this cap covers extremely large
/// render targets while rejecting corrupt descriptors before allocation.
const maximum_cmask_bytes = 4 * 1024 * 1024;
/// HTILE is one dword per 8x8 region. This cap covers depth arrays far larger
/// than the current attachment path while rejecting corrupt dimensions.
const maximum_htile_bytes = 8 * 1024 * 1024;
/// On-disk driver pipeline cache. Reused across runs so per-title shader
/// compilation is paid once instead of on every launch.
const pipeline_cache_path = "vulkan_pipeline_cache.bin";
/// Sanity cap: a pipeline cache payload this large is not ours.
const maximum_pipeline_cache_bytes = 64 * 1024 * 1024;

/// Reads the persisted driver pipeline cache, if any. Any failure — missing
/// file, unreadable file, unreasonable size — returns null; the caller then
/// creates an empty cache and saves over it later.
fn loadPipelineCacheBytes(allocator: std.mem.Allocator) ?[]u8 {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, pipeline_cache_path, .{}) catch return null;
    defer file.close(io);
    const size = file.length(io) catch return null;
    if (size == 0 or size > maximum_pipeline_cache_bytes) return null;
    const bytes = allocator.alloc(u8, @intCast(size)) catch return null;
    errdefer allocator.free(bytes);
    const read = file.readPositionalAll(io, bytes, 0) catch return null;
    if (read != bytes.len) return null;
    return bytes;
}

/// Writes the current driver pipeline cache to disk. Failure is deliberately
/// silent: a cache is an optimization, and losing it only costs compilation
/// time on the next run.
fn savePipelineCacheBytes(self: *Renderer) void {
    var data_size: usize = 0;
    if (self.device_functions.get_pipeline_cache_data(self.device, self.driver_pipeline_cache, &data_size, null) != vk.success) {
        return;
    }
    if (data_size == 0 or data_size > maximum_pipeline_cache_bytes) return;
    const bytes = self.allocator.alloc(u8, data_size) catch return;
    defer self.allocator.free(bytes);
    if (self.device_functions.get_pipeline_cache_data(self.device, self.driver_pipeline_cache, &data_size, bytes.ptr) != vk.success) {
        return;
    }
    var threaded = std.Io.Threaded.init(self.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = std.Io.Dir.cwd().createFile(io, pipeline_cache_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    file.writePositionalAll(io, bytes, 0) catch return;
}

const GuestBufferEntry = struct {
    descriptor_index: u32,
    guest_address: u64,
    size: vk.DeviceSize,
    device_local: OwnedBuffer,
    last_used_sequence: u64,
    gpu_dirty: bool = false,
};

const ComputePipelineEntry = struct {
    hash: u64,
    words: []u32,
    shader: vk.ShaderModule,
    pipeline: vk.Pipeline,
};

const GraphicsPipelineEntry = struct {
    hash: u64,
    state_hash: u64,
    vertex_hash: u64,
    fragment_hash: u64,
    state: GraphicsPipelineState,
    vertex_words: []u32,
    fragment_words: []u32,
    pipeline: vk.Pipeline,
    last_used_sequence: u64,
};

const GraphicsPipelineState = extern struct {
    width: u32,
    height: u32,
    color_attachment_format: u32,
    topology: u32,
    viewport_x_bits: u32,
    viewport_y_bits: u32,
    viewport_width_bits: u32,
    viewport_height_bits: u32,
    viewport_min_depth_bits: u32,
    viewport_max_depth_bits: u32,
    scissor_x: i32,
    scissor_y: i32,
    scissor_width: u32,
    scissor_height: u32,
    cull_mode: u32,
    front_face: u32,
    rasterizer_discard: u32,
    color_write_mask: u32,
    blend_enable: u32,
    source_color_blend_factor: u32,
    destination_color_blend_factor: u32,
    color_blend_operation: u32,
    source_alpha_blend_factor: u32,
    destination_alpha_blend_factor: u32,
    alpha_blend_operation: u32,
    /// Zero when the draw has no depth attachment. A pipeline is only
    /// compatible with a render pass that agrees about depth, so this belongs
    /// in the cache key.
    depth_attachment_format: u32,
    depth_test_enable: u32,
    depth_write_enable: u32,
    depth_compare_operation: u32,

    fn default(width: u32, height: u32) GraphicsPipelineState {
        return .{
            .width = width,
            .height = height,
            .color_attachment_format = vk.format_r8g8b8a8_unorm,
            .topology = vk.primitive_topology_triangle_list,
            .viewport_x_bits = @bitCast(@as(f32, 0)),
            .viewport_y_bits = @bitCast(@as(f32, 0)),
            .viewport_width_bits = @bitCast(@as(f32, @floatFromInt(width))),
            .viewport_height_bits = @bitCast(@as(f32, @floatFromInt(height))),
            .viewport_min_depth_bits = @bitCast(@as(f32, 0)),
            .viewport_max_depth_bits = @bitCast(@as(f32, 1)),
            .scissor_x = 0,
            .scissor_y = 0,
            .scissor_width = width,
            .scissor_height = height,
            .cull_mode = 0,
            .front_face = 1,
            .rasterizer_discard = 0,
            .color_write_mask = vk.color_component_rgba_bits,
            .blend_enable = 0,
            .source_color_blend_factor = 0,
            .destination_color_blend_factor = 0,
            .color_blend_operation = 0,
            .source_alpha_blend_factor = 0,
            .destination_alpha_blend_factor = 0,
            .alpha_blend_operation = 0,
            .depth_attachment_format = 0,
            .depth_test_enable = 0,
            .depth_write_enable = 0,
            .depth_compare_operation = 0,
        };
    }
};

const ColorTargetFormat = struct {
    vulkan: u32,
    bytes_per_texel: u8,
};

const GuestColorTarget = struct {
    descriptor: gpu.resources.ColorTarget,
    layout: gpu.SurfaceLayout,
    format: ColorTargetFormat,
};

/// How a graphics packet wants geometry issued on the host.
const GuestDraw = struct {
    /// Non-indexed `DRAW_INDEX_AUTO` path (diagnostic triangle is count 3).
    vertex_count: u32 = 3,
    instance_count: u32 = 1,
    /// When set, issue `vkCmdDrawIndexed` from guest memory at `index_address`.
    index_count: ?u32 = null,
    index_address: u64 = 0,
    /// `false` = UINT16, `true` = UINT32. AGC defaults to 16-bit indices.
    index_uint32: bool = false,
};

fn guestPrimitiveTopology(primitive_type: u32, draw: GuestDraw) u32 {
    return switch (primitive_type) {
        1 => vk.primitive_topology_point_list,
        2 => vk.primitive_topology_line_list,
        3, 18 => vk.primitive_topology_line_strip,
        5 => vk.primitive_topology_triangle_fan,
        6 => vk.primitive_topology_triangle_strip,
        // PS5 NGG rectangle lists use a four-vertex auto draw as a host
        // triangle strip. Indexed and batched rectangle lists already carry
        // expanded triangle-list indices and must retain triangle-list order.
        7 => if (draw.index_count == null and draw.vertex_count <= 4)
            vk.primitive_topology_triangle_strip
        else
            vk.primitive_topology_triangle_list,
        17 => if (draw.index_count == null)
            vk.primitive_topology_triangle_strip
        else
            vk.primitive_topology_triangle_list,
        else => vk.primitive_topology_triangle_list,
    };
}

/// Some graphics passes omit CB registers because the following VideoOut flip
/// names the scanout allocation. Preserve every draw and its complete state so
/// the pass can be replayed in order once that allocation is known.
const PendingGuestDraw = struct {
    state: gpu.State,
    draw: GuestDraw,
    vertex_stage: gpu.resources.ShaderStage,
};

const maximum_pending_targetless_draws: usize = 256;

const ComputeShaderFailure = struct {
    address: u64,
    err: anyerror,
};

const GraphicsShaderFailure = struct {
    address: u64,
    stage: gpu.resources.ShaderStage,
    err: anyerror,
};

fn colorTargetFormat(descriptor: gpu.resources.ColorTarget) ?ColorTargetFormat {
    return switch (descriptor.format) {
        // DATA_FORMAT_8_8_8_8. Preserve the existing UNORM attachment path
        // for the number-type variants titles have already exercised.
        10 => .{ .vulkan = vk.format_r8g8b8a8_unorm, .bytes_per_texel = 4 },
        // DATA_FORMAT_16_16_16_16 + NUMBER_FORMAT_FLOAT.
        12 => if (descriptor.number_type == 7)
            .{ .vulkan = vk.format_r16g16b16a16_sfloat, .bytes_per_texel = 8 }
        else
            null,
        else => null,
    };
}

/// The Vulkan attachment format for a guest depth plane.
///
/// DB_Z_INFO.FORMAT names the stored precision: 1 is sixteen-bit unorm and 3 is
/// thirty-two bit float. Both have a direct Vulkan counterpart, so nothing is
/// approximated here; formats outside that pair are left unsupported instead of
/// being forced into a nearby one, because silently changing depth precision
/// changes which fragments a title keeps.
fn depthTargetFormat(descriptor: gpu.resources.DepthTarget) ?u32 {
    return switch (descriptor.format) {
        1 => vk.format_d16_unorm,
        3 => vk.format_d32_sfloat,
        else => null,
    };
}

/// The guest depth-compare selector and Vulkan's `VkCompareOp` enumerate the
/// same eight functions in the same order, so the raw field is the host value.
fn depthCompareOperation(function: u8) u32 {
    return @as(u32, function & 0x7);
}

/// The first host implementation keeps one color value per pixel.  Preserve
/// the guest allocation and fixed-function resolve semantics while rendering
/// an MSAA target as a single-sample attachment; a later CB resolve copies the
/// resulting pixels to its single-sample destination.
fn hostColorTargetDescriptor(descriptor: gpu.resources.ColorTarget) gpu.resources.ColorTarget {
    var host = descriptor;
    host.samples_log2 = 0;
    host.fragments_log2 = 0;
    host.fmask_compression = false;
    host.fmask_address = 0;
    return host;
}

fn guestColorTarget(descriptor_: gpu.resources.ColorTarget) anyerror!GuestColorTarget {
    if (descriptor_.samples_log2 > 3 or descriptor_.fragments_log2 > descriptor_.samples_log2) {
        return Error.UnsupportedColorTarget;
    }
    const descriptor = hostColorTargetDescriptor(descriptor_);
    const format = colorTargetFormat(descriptor) orelse return Error.UnsupportedColorTarget;
    const layout = try gpu.SurfaceLayout.fromColorTarget(descriptor);
    if (layout.layers != 1 or layout.block.bytes_per_element != format.bytes_per_texel) {
        return Error.UnsupportedColorTarget;
    }
    return .{ .descriptor = descriptor, .layout = layout, .format = format };
}

fn displayColorTarget(buffer: DisplayBuffer) ?gpu.resources.ColorTarget {
    if (buffer.address == 0 or buffer.width == 0 or buffer.height == 0) return null;
    const pitch = if (buffer.pitch_in_pixels != 0) buffer.pitch_in_pixels else buffer.width;
    if (pitch < buffer.width) return null;
    const tile_mode: gpu.resources.TileMode = switch (buffer.tiling_mode) {
        0 => .render_target,
        1 => .linear,
        else => return null,
    };
    var target = std.mem.zeroes(gpu.resources.ColorTarget);
    target.address = buffer.address;
    target.width = buffer.width;
    target.height = buffer.height;
    target.depth = 1;
    target.pitch = pitch;
    // DATA_FORMAT_8_8_8_8. VideoOut's pixel format is a separate unified
    // format enum; the colour-target descriptor stores the data format only.
    target.format = 10;
    target.tile_mode = tile_mode;
    target.write_mask = 0xf;
    target.force_destination_alpha_one = true;
    return target;
}

/// One guest color allocation kept resident as a Vulkan attachment across
/// draws.  The old path recreated this entire object graph and round-tripped
/// every pixel through the CPU after each draw, which both destroyed
/// multi-pass composition and serialized the host GPU.
const CachedRenderTarget = struct {
    target: GuestColorTarget,
    image: OwnedImage,
    view: vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    depth_pass: ?DepthPass = null,
    readback: OwnedBuffer,
    initialized: bool = false,
    shader_read_layout: bool = false,
    gpu_generation: u64 = 0,
    host_generation: u64 = 0,
    last_used_sequence: u64 = 0,
};

/// A guest depth allocation reduced to what a Vulkan attachment needs.
///
/// The guest describes depth as a base allocation plus an optional separate
/// stencil allocation and an HTILE metadata surface. Only the depth plane is
/// represented here: stencil has no translation yet, and HTILE is resolved into
/// the base allocation by the existing metadata path rather than being handed to
/// the rasterizer.
const GuestDepthTarget = struct {
    address: u64,
    width: u32,
    height: u32,
    /// DB_Z_INFO.FORMAT, kept so a re-decode of the same registers matches.
    guest_format: u8,
    format: u32,
    tile_mode: gpu.resources.TileMode,
    base_array_slice: u16,
    mip_level: u8,
    clear_depth: f32,

    fn sameAllocation(self: GuestDepthTarget, other: GuestDepthTarget) bool {
        return self.address == other.address and
            self.width == other.width and
            self.height == other.height and
            self.guest_format == other.guest_format and
            self.tile_mode == other.tile_mode and
            self.base_array_slice == other.base_array_slice and
            self.mip_level == other.mip_level;
    }
};

/// One guest depth allocation kept resident as a Vulkan attachment.
///
/// The image is not staged from guest memory and is never read back. A title
/// establishes depth by clearing it and then testing against what its own draws
/// wrote, so the contents only have to be consistent from the first clear
/// onwards; importing tiled guest depth would add a conversion this path does
/// not need yet.
const CachedDepthTarget = struct {
    target: GuestDepthTarget,
    image: OwnedImage,
    view: vk.ImageView,
    /// False until the image has been transitioned out of `undefined`.
    initialized: bool = false,
    last_used_sequence: u64 = 0,
};

/// A render pass and framebuffer pairing one colour attachment with one depth
/// attachment.
///
/// Held on the colour target because that is what owns the framebuffer. A title
/// keeps the same pair bound across long runs of draws, so the single slot is
/// rebuilt only when the depth allocation actually changes.
const DepthPass = struct {
    depth_view: vk.ImageView,
    depth_format: u32,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
};

const CmaskSeed = struct {
    texel: [4]u8,
    clear_blocks: u32,
    expanded_blocks: u32,
};

const DccClearTexel = struct {
    bytes: [8]u8,
    length: u8,
};

const CachedHtileTarget = struct {
    target: gpu.resources.DepthTarget,
    resolved: bool = false,
    last_used_sequence: u64 = 0,
};

const HtileResolveStats = struct {
    clear_zero_blocks: u32 = 0,
    clear_one_blocks: u32 = 0,
    base_blocks: u32 = 0,

    fn clearBlocks(self: HtileResolveStats) u32 {
        return self.clear_zero_blocks +| self.clear_one_blocks;
    }
};

/// One remembered content probe of a sampled source.
///
/// The probe reads a spread of cache lines out of guest memory, and a frame
/// samples the same few textures from many draws. Repeating the read for every
/// draw costs more than the comparison it feeds, so the result is remembered
/// for as long as the source cannot have changed: the same span, and the same
/// render-target generation behind it.
const TextureProbe = struct {
    address: u64 = 0,
    span: usize = 0,
    source_generation: u64 = 0,
    hash: u64 = 0,
    valid: bool = false,
};

/// Distinct sampled sources remembered per frame. A title binding more than
/// this many in one frame simply re-probes the ones that fall out.
const maximum_texture_probes = 32;

/// Whether guest memory still holds the words a program was decoded from.
fn programWordsMatch(reader: gpu.ShaderMemoryReader, address: u64, words: []const u32) bool {
    const expected = std.mem.sliceAsBytes(words);
    var chunk: [1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const span = @min(chunk.len, expected.len - offset);
        if (!reader.read_fn(reader.context, address + offset, chunk[0..span])) return false;
        if (!std.mem.eql(u8, chunk[0..span], expected[offset..][0..span])) return false;
        offset += span;
    }
    return true;
}

/// One guest shader program in decoded form.
///
/// `analysis` owns the words it was decoded from, and those words are what a
/// later lookup compares against guest memory, so no separate copy is kept.
const AnalyzedProgram = struct {
    address: u64,
    analysis: gpu.ShaderAnalysis,
    last_used_sequence: u64 = 0,
};

const FrameProfile = struct {
    draws: u64 = 0,
    dispatches: u64 = 0,
    submits: u64 = 0,
    fence_wait_ns: u64 = 0,
    upload_bytes: u64 = 0,
    readback_bytes: u64 = 0,
    storage_upload_bytes: u64 = 0,
    storage_readback_bytes: u64 = 0,
    target_upload_bytes: u64 = 0,
    target_readback_bytes: u64 = 0,
    texture_upload_bytes: u64 = 0,
    index_upload_bytes: u64 = 0,
    draw_ns: u64 = 0,
    dispatch_ns: u64 = 0,
    storage_stage_ns: u64 = 0,
    storage_commit_ns: u64 = 0,
    target_materialize_ns: u64 = 0,
    resident_storage_bytes: u64 = 0,
    render_target_hits: u64 = 0,
    render_target_misses: u64 = 0,
    graphics_pipeline_hits: u64 = 0,
    graphics_pipeline_misses: u64 = 0,
    graphics_pipeline_miss_state_match: u64 = 0,
    graphics_pipeline_miss_vertex_match: u64 = 0,
    graphics_pipeline_miss_fragment_match: u64 = 0,
    graphics_pipeline_build_ns: u64 = 0,
    shader_analysis_hits: u64 = 0,
    shader_analysis_misses: u64 = 0,
    shader_analysis_ns: u64 = 0,
    scalar_provenance_ns: u64 = 0,
    shader_translate_ns: u64 = 0,
    graphics_resource_ns: u64 = 0,
    texture_probe_ns: u64 = 0,

    fn reset(self: *FrameProfile) void {
        self.* = .{};
    }
};

const CachedFrame = struct {
    pixels: std.ArrayList(u8) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    guest_address: u64 = 0,
    sequence: u64 = 0,
    /// Tiling metadata of the render that produced `pixels`, retained so a
    /// deferred (lazy) writeback can tile the linear frame back into guest
    /// memory when the guest actually needs it.
    target: ?GuestColorTarget = null,
    /// The guest allocation at `guest_address` is stale: the rendered frame
    /// has not been tiled back into guest memory yet.
    needs_writeback: bool = false,
};

const WindowPresentation = struct {
    native_window: NativeWindow,
    surface_functions: SurfaceFunctions,
    swapchain_functions: SwapchainFunctions,
    surface: vk.Surface,
    swapchain: vk.Swapchain,
    images: []vk.Image,
    extent: vk.Extent2D,
    format: u32,
    /// Persistent host-visible transfer source for swapchain uploads. Created
    /// once at swapchain setup instead of per present, so a flip no longer
    /// allocates a buffer and device memory on every frame.
    upload: OwnedBuffer,
    /// Persistent acquire fence, reset and reused by every batched present.
    acquire_fence: vk.Fence,
};

const PreparedSampledImage = struct {
    image: OwnedImage,
    view: vk.ImageView,
    sampler: vk.Sampler,
    owns_view: bool = false,
    owns_sampler: bool = false,
};

const SampledStagingLayout = union(enum) {
    surface: gpu.SurfaceLayout,
    subresource: gpu.TextureSubresourceLayout,

    fn fromImage(descriptor: gpu.resources.ImageDescriptor) anyerror!SampledStagingLayout {
        if (descriptor.image_type == .color_3d) {
            const texture = try gpu.TextureLayout.fromImage(descriptor);
            return .{ .subresource = try texture.base() };
        }
        return .{ .surface = try gpu.SurfaceLayout.fromImage(descriptor) };
    }

    fn depthOrLayers(self: SampledStagingLayout) u32 {
        return switch (self) {
            .surface => |layout| layout.layers,
            .subresource => |layout| layout.depth_or_layers,
        };
    }

    fn bytesPerElement(self: SampledStagingLayout) u8 {
        return switch (self) {
            .surface => |layout| layout.block.bytes_per_element,
            .subresource => |layout| layout.block.bytes_per_element,
        };
    }

    fn isLinear(self: SampledStagingLayout) bool {
        return switch (self) {
            .surface => |layout| layout.block.tile_mode.isLinear(),
            .subresource => |layout| layout.block.family == .linear,
        };
    }

    fn stagingBytes(self: SampledStagingLayout) anyerror!u64 {
        return switch (self) {
            .surface => |layout| layout.staging_bytes,
            .subresource => |layout| try layout.stagingBytes(),
        };
    }

    fn requiredSourceBytes(self: SampledStagingLayout) u64 {
        return switch (self) {
            .surface => |layout| layout.required_source_bytes,
            .subresource => |layout| layout.required_source_bytes,
        };
    }

    fn stage(
        self: SampledStagingLayout,
        reader: gpu.ShaderMemoryReader,
        address: u64,
        destination: []u8,
    ) anyerror!void {
        return switch (self) {
            .surface => |layout| try layout.stage(reader, address, destination),
            .subresource => |layout| try layout.stage(reader, address, destination),
        };
    }

    fn detile(self: SampledStagingLayout, source: []const u8, destination: []u8) anyerror!void {
        return switch (self) {
            .surface => |layout| try layout.detile(source, destination),
            .subresource => |layout| try layout.detile(source, destination),
        };
    }
};

const PreparedStorageImage = struct {
    descriptor: gpu.ImageDescriptor,
    subresource: gpu.TextureSubresourceLayout,
    image: OwnedImage,
    view: vk.ImageView,
    transfer: OwnedBuffer,
    allocation_bytes: usize,
    staging_bytes: usize,
    writable: bool,
};

const GraphicsResources = struct {
    images: [maximum_storage_descriptors]PreparedSampledImage = undefined,
    image_count: usize = 0,
    descriptors: [maximum_storage_descriptors]gpu.ImageDescriptor = undefined,
    mappings: [maximum_storage_descriptors]gpu.ShaderSpirvSampledImageBinding = undefined,
    mapping_count: usize = 0,

    fn deinit(self: *GraphicsResources, renderer: *Renderer) void {
        for (self.images[0..self.image_count]) |image| {
            if (image.owns_view) renderer.device_functions.destroy_image_view(renderer.device, image.view, null);
            if (image.owns_sampler) renderer.device_functions.destroy_sampler(renderer.device, image.sampler, null);
        }
        self.* = undefined;
    }
};

const PipelineLookup = struct {
    pipeline: vk.Pipeline,
    cache_hit: bool,
};

const ComputeResources = struct {
    mappings: [maximum_storage_mappings]gpu.ShaderSpirvStorageBufferBinding = undefined,
    mapping_count: usize = 0,
    scalar_registers: [gpu.scalar_provenance.maximum_scalar_specializations]gpu.ShaderSpirvScalarRegister = undefined,
    scalar_count: usize = 0,
    addresses: [maximum_storage_descriptors]u64 = @splat(0),
    sizes: [maximum_storage_descriptors]usize = @splat(0),
    occupied: [maximum_storage_descriptors]bool = @splat(false),
    writable: [maximum_storage_descriptors]bool = @splat(false),
    specialized_scalar_prefix_end: u32 = 0,
    storage_images: [maximum_storage_images]PreparedStorageImage = undefined,
    storage_image_count: usize = 0,
    storage_image_mappings: [maximum_storage_images]gpu.ShaderSpirvStorageImageBinding = undefined,
    storage_image_mapping_count: usize = 0,
    sampled_images: [maximum_storage_descriptors]PreparedSampledImage = undefined,
    sampled_image_count: usize = 0,
    sampled_image_mappings: [maximum_storage_descriptors]gpu.ShaderSpirvSampledImageBinding = undefined,
    sampled_image_mapping_count: usize = 0,

    fn descriptorForRange(self: *const ComputeResources, address: u64, size: usize) ?u32 {
        for (self.occupied, 0..) |used, index| {
            if (used and self.addresses[index] == address and self.sizes[index] == size) return @intCast(index);
        }
        return null;
    }

    fn freeDescriptor(self: *const ComputeResources) ?u32 {
        for (self.occupied, 0..) |used, index| {
            if (!used) return @intCast(index);
        }
        return null;
    }

    fn mappingForSgpr(self: *const ComputeResources, resource_sgpr: u32) ?u32 {
        for (self.mappings[0..self.mapping_count]) |mapping| {
            if (mapping.resource_sgpr == resource_sgpr) return mapping.descriptor_index;
        }
        return null;
    }

    fn storageImageMappingForSgpr(self: *const ComputeResources, resource_sgpr: u32) ?u32 {
        for (self.storage_image_mappings[0..self.storage_image_mapping_count]) |mapping| {
            if (mapping.resource_sgpr == resource_sgpr) return mapping.descriptor_index;
        }
        return null;
    }

    fn sampledImageMappingForInstruction(
        self: *const ComputeResources,
        resource_sgpr: u32,
        sampler_sgpr: u32,
        instruction_pc: u32,
    ) ?u32 {
        for (self.sampled_image_mappings[0..self.sampled_image_mapping_count]) |mapping| {
            if (mapping.resource_sgpr == resource_sgpr and
                mapping.sampler_sgpr == sampler_sgpr and
                mapping.instruction_pc != null and mapping.instruction_pc.? == instruction_pc)
            {
                return mapping.descriptor_index;
            }
        }
        return null;
    }

    fn deinit(self: *ComputeResources, renderer: *Renderer) void {
        for (self.storage_images[0..self.storage_image_count]) |image| {
            renderer.device_functions.destroy_image_view(renderer.device, image.view, null);
            renderer.destroyImage(image.image);
            renderer.destroyBuffer(image.transfer);
        }
        self.storage_image_count = 0;
        self.storage_image_mapping_count = 0;
        // Cached sampled images survive this dispatch. Direct render-target
        // views and samplers are temporary because submissions are synchronous.
        for (self.sampled_images[0..self.sampled_image_count]) |image| {
            if (image.owns_view) renderer.device_functions.destroy_image_view(renderer.device, image.view, null);
            if (image.owns_sampler) renderer.device_functions.destroy_sampler(renderer.device, image.sampler, null);
        }
        self.sampled_image_count = 0;
        self.sampled_image_mapping_count = 0;
    }
};

fn canReuseStorageMapping(attribute_specific: bool, previous: ?u32, current: u32) bool {
    return !attribute_specific and previous != null and previous.? == current;
}

fn shouldDumpProgressFrame(flip: u64) bool {
    return switch (flip) {
        8, 16, 32, 64, 96, 128 => true,
        else => false,
    };
}

const CachedSampledImage = struct {
    guest_address: u64,
    width: u32,
    height: u32,
    depth: u32,
    image_type: u8,
    tile_mode: u8,
    state_hash: u64,
    source_generation: u64,
    content_hash: u64,
    image: OwnedImage,
    view: vk.ImageView,
    sampler: vk.Sampler,
    last_used_frame: u64,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    loader: Loader,
    instance_handle: vk.Instance,
    instance_functions: InstanceFunctions,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    device_functions: DeviceFunctions,
    queue: vk.Queue,
    queue_family_index: u32,
    command_pool: vk.CommandPool,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    dynamic_scalar_buffer: ?OwnedBuffer = null,
    dynamic_scalar_mapping: ?[*]u32 = null,
    /// All current submissions complete before returning, so one fence can be
    /// reset and reused instead of allocating a kernel object per draw.
    one_shot_fence: vk.Fence = 0,
    one_shot_command_buffer: ?vk.CommandBuffer = null,
    compute_pipeline_layout: vk.PipelineLayout,
    driver_pipeline_cache: vk.PipelineCache,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    loader_api_version: u32,
    device_info: DeviceInfo,
    validation_enabled: bool,
    graphics_probe_enabled: bool,
    capture_first_graphics_frame: bool,
    force_probe_fragment: bool,
    force_probe_fragment_texture: bool,
    force_probe_fragment_parameter: bool,
    force_probe_fragment_ui: bool,
    skip_compute_dispatches: bool,
    translate_compute_only: bool,
    guest_memory: ?GuestMemory = null,
    /// Holds a display buffer read straight out of guest memory, for a flip
    /// that names a buffer nothing was rendered into.
    guest_frame_scratch: std.ArrayList(u8) = .empty,
    guest_buffers: std.ArrayList(GuestBufferEntry) = .empty,
    guest_buffer_sequence: u64 = 0,
    gds_storage: std.ArrayList(u8) = .empty,
    compute_pipelines: std.ArrayList(ComputePipelineEntry) = .empty,
    graphics_pipelines: std.ArrayList(GraphicsPipelineEntry) = .empty,
    sampled_image_cache: std.ArrayList(CachedSampledImage) = .empty,
    /// Decoded shader programs, held across draws. Its capacity is reserved
    /// once so entries never move: callers hold `*const Analysis` into it for
    /// the length of a draw.
    analyzed_programs: std.ArrayList(AnalyzedProgram) = .empty,
    analyzed_program_sequence: u64 = 0,
    texture_probes: [maximum_texture_probes]TextureProbe = @splat(.{}),
    texture_probe_count: usize = 0,
    texture_cache_hits: u64 = 0,
    texture_cache_misses: u64 = 0,
    active_descriptor_set: ?vk.DescriptorSet = null,
    draw_callbacks: u64 = 0,
    translated_draws: u64 = 0,
    guest_graphics_draws: u64 = 0,
    targetless_draws_deferred: u64 = 0,
    targetless_draws_resolved: u64 = 0,
    graphics_probe_colored_pixels: u32 = 0,
    graphics_probe_frame: [graphics_probe_bytes]u8 = @splat(0),
    render_targets: std.ArrayList(CachedRenderTarget) = .empty,
    depth_targets: std.ArrayList(CachedDepthTarget) = .empty,
    depth_target_sequence: u64 = 0,
    reported_depth_attachment: bool = false,
    htile_targets: std.ArrayList(CachedHtileTarget) = .empty,
    htile_target_sequence: u64 = 0,
    latest_render_target_index: ?usize = null,
    render_target_sequence: u64 = 0,
    completed_frames: std.ArrayList(CachedFrame) = .empty,
    latest_frame_index: ?usize = null,
    frame_sequence: u64 = 0,
    presentation_sink: ?PresentationSink = null,
    frame_rate_sink: ?FrameRateSink = null,
    frame_rate_counter: FrameRateCounter = .{},
    display_buffer_resolver: ?DisplayBufferResolver = null,
    pending_targetless_draws: std.ArrayList(PendingGuestDraw) = .empty,
    window_presentation: ?WindowPresentation = null,
    presented_frames: u64 = 0,
    /// Batched present queue. Only the most recent frame survives: a burst of
    /// flips or eager presents collapses to a single swapchain present, and a
    /// swapchain that cannot accept another image drops the frame instead of
    /// stalling the emulator on acquire.
    pending_present: ?PresentedFrame = null,
    present_in_flight: bool = false,
    /// Frames skipped because the swapchain had no free image yet. A count,
    /// not an error: dropping stale frames is how a real display pipeline
    /// paces itself.
    present_dropped: u64 = 0,
    guest_color_target_writes: u64 = 0,
    sampled_image_uploads: u64 = 0,
    acquire_callbacks: u64 = 0,
    release_callbacks: u64 = 0,
    wait_callbacks: u64 = 0,
    write_data_callbacks: u64 = 0,
    dma_data_callbacks: u64 = 0,
    event_callbacks: u64 = 0,
    flip_callbacks: u64 = 0,
    /// Host presents issued immediately after a guest color writeback, so a
    /// frame is visible even if the title crashes before SetFlip.
    eager_presents: u64 = 0,
    frame_dumps: u64 = 0,
    dispatch_callbacks: u64 = 0,
    translated_dispatches: u64 = 0,
    elided_dispatches: u64 = 0,
    emulated_gds_dispatches: u64 = 0,
    emulated_buffer_clear_dispatches: u64 = 0,
    emulated_image_store_dispatches: u64 = 0,
    emulated_image_copy_dispatches: u64 = 0,
    video_surface_addresses: [8]u64 = @splat(0),
    video_surface_count: usize = 0,
    video_surface_last_flip: u64 = 0,
    latest_video_render_target_index: ?usize = null,
    emulated_volume_copies: u64 = 0,
    reported_dual_image_clear_fallback: bool = false,
    reported_fast_clear_seeds: u32 = 0,
    reported_non_rgba_materializations: u32 = 0,
    reported_htile_resolves: u32 = 0,
    reported_color_resolves: u32 = 0,
    buffer_cache_hits: u64 = 0,
    buffer_cache_misses: u64 = 0,
    buffer_uploads: u64 = 0,
    pipeline_cache_hits: u64 = 0,
    pipeline_cache_misses: u64 = 0,
    graphics_pipeline_cache_hits: u64 = 0,
    graphics_pipeline_cache_misses: u64 = 0,
    graphics_pipeline_sequence: u64 = 0,
    frame_profile: FrameProfile = .{},
    last_flip_profile_ns: u64 = 0,
    reported_shader_failures: [64]?GraphicsShaderFailure = @splat(null),
    reported_vertex_resource_programs: [16]u64 = @splat(0),
    reported_fragment_resource_programs: [16]u64 = @splat(0),
    last_interface_vertex_address: u64 = 0,
    last_interface_fragment_address: u64 = 0,
    reported_interface_pairs: u8 = 0,
    reported_vertex_storage_bindings: bool = false,
    reported_fragment_storage_bindings: bool = false,
    reported_first_graphics_draw_checkpoints: bool = false,
    captured_targeted_fragment_probe: bool = false,
    reported_planar_video_pass: bool = false,
    captured_planar_video_pass: bool = false,
    reported_first_scissor_state: bool = false,
    reported_draw_errors: [16]?anyerror = @splat(null),
    reported_compute_shader_failures: [32]?ComputeShaderFailure = @splat(null),
    reported_compute_resource_programs: [32]u64 = @splat(0),
    last_dispatch_error: ?anyerror = null,
    last_draw_error: ?anyerror = null,
    last_sync_error: ?anyerror = null,
    last_flip_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) (Error || std.mem.Allocator.Error)!Renderer {
        const wants_presentation = options.native_window != null;
        if (wants_presentation and builtin.os.tag != .windows) return Error.UnsupportedPresentationPlatform;
        var loader = try Loader.init();
        errdefer loader.deinit();

        const enumerate_version = try loader.global(vk.PfnEnumerateInstanceVersion, "vkEnumerateInstanceVersion");
        var loader_api_version: u32 = 0;
        if (enumerate_version(&loader_api_version) != vk.success or loader_api_version < vk.api_version_1_2) {
            return Error.VulkanVersionTooOld;
        }

        const enumerate_layers = try loader.global(vk.PfnEnumerateInstanceLayerProperties, "vkEnumerateInstanceLayerProperties");
        const validation_enabled = options.enable_validation and layerAvailable(enumerate_layers, "VK_LAYER_KHRONOS_validation");
        const validation_name: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
        const layer_names = [_][*:0]const u8{validation_name};
        const instance_extension_names = [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_win32_surface",
        };

        const application_info = vk.ApplicationInfo{
            .application_name = "PS5PCEM",
            .application_version = vk.makeApiVersion(0, 0, 4, 0),
            .engine_name = "PS5PCEM",
            .engine_version = vk.makeApiVersion(0, 0, 4, 0),
            .api_version = vk.api_version_1_2,
        };
        const instance_info = vk.InstanceCreateInfo{
            .application_info = &application_info,
            .enabled_layer_count = @intFromBool(validation_enabled),
            .enabled_layer_names = if (validation_enabled) &layer_names else null,
            .enabled_extension_count = if (wants_presentation) instance_extension_names.len else 0,
            .enabled_extension_names = if (wants_presentation) &instance_extension_names else null,
        };
        const create_instance = try loader.global(vk.PfnCreateInstance, "vkCreateInstance");
        var maybe_instance: ?vk.Instance = null;
        if (create_instance(&instance_info, null, &maybe_instance) != vk.success) return Error.InstanceCreationFailed;
        const instance_handle = maybe_instance orelse return Error.InstanceCreationFailed;
        const instance_functions = try InstanceFunctions.load(&loader, instance_handle);
        errdefer instance_functions.destroy_instance(instance_handle, null);

        const surface_functions: ?SurfaceFunctions = if (wants_presentation)
            try SurfaceFunctions.load(&loader, instance_handle)
        else
            null;
        var surface: vk.Surface = 0;
        if (options.native_window) |window| {
            const surface_info = vk.Win32SurfaceCreateInfoKHR{
                .instance = window.instance,
                .window = window.window,
            };
            if (surface_functions.?.create_win32_surface(instance_handle, &surface_info, null, &surface) != vk.success) {
                return Error.SurfaceCreationFailed;
            }
        }
        errdefer if (surface != 0) surface_functions.?.destroy_surface(instance_handle, surface, null);

        const candidate = try choosePhysicalDevice(
            allocator,
            instance_handle,
            &instance_functions,
            surface,
            if (surface_functions) |*functions| functions else null,
        );
        const queue_priority: f32 = 1.0;
        const queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = candidate.queue_family_index,
            .queue_count = 1,
            .queue_priorities = @ptrCast(&queue_priority),
        };
        const device_extension_names = [_][*:0]const u8{"VK_KHR_swapchain"};
        const device_info = vk.DeviceCreateInfo{
            .queue_create_info_count = 1,
            .queue_create_infos = @ptrCast(&queue_info),
            .enabled_extension_count = if (wants_presentation) device_extension_names.len else 0,
            .enabled_extension_names = if (wants_presentation) &device_extension_names else null,
        };
        var maybe_device: ?vk.Device = null;
        if (instance_functions.create_device(candidate.physical_device, &device_info, null, &maybe_device) != vk.success) {
            return Error.DeviceCreationFailed;
        }
        const device = maybe_device orelse return Error.DeviceCreationFailed;
        const device_functions = try DeviceFunctions.load(instance_functions.get_device_proc_addr, device);
        errdefer device_functions.destroy_device(device, null);
        const swapchain_functions: ?SwapchainFunctions = if (wants_presentation)
            try SwapchainFunctions.load(instance_functions.get_device_proc_addr, device)
        else
            null;

        var maybe_queue: ?vk.Queue = null;
        device_functions.get_device_queue(device, candidate.queue_family_index, 0, &maybe_queue);
        const queue = maybe_queue orelse return Error.QueueUnavailable;

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = vk.command_pool_create_transient_bit | vk.command_pool_create_reset_command_buffer_bit,
            .queue_family_index = candidate.queue_family_index,
        };
        var command_pool: vk.CommandPool = 0;
        if (device_functions.create_command_pool(device, &pool_info, null, &command_pool) != vk.success) {
            return Error.CommandPoolCreationFailed;
        }
        errdefer device_functions.destroy_command_pool(device, command_pool, null);

        // Storage is shared by compute and by graphics attribute / constant
        // buffer MUBUF lowering. Restricting it to compute left guest VS loads
        // unbound and produced a black writeback after V# recovery.
        const storage_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = vk.descriptor_type_storage_buffer,
            .descriptor_count = maximum_storage_descriptors,
            .stage_flags = vk.shader_stage_compute_bit |
                vk.shader_stage_vertex_bit |
                vk.shader_stage_fragment_bit,
        };
        const sampled_image_binding = vk.DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptor_type = vk.descriptor_type_combined_image_sampler,
            .descriptor_count = maximum_storage_descriptors,
            .stage_flags = vk.shader_stage_fragment_bit | vk.shader_stage_compute_bit,
        };
        var descriptor_bindings: [4 + maximum_storage_images]vk.DescriptorSetLayoutBinding = undefined;
        descriptor_bindings[0] = storage_binding;
        descriptor_bindings[1] = sampled_image_binding;
        for (0..maximum_storage_images) |index| {
            descriptor_bindings[2 + index] = .{
                .binding = @intCast(2 + index),
                .descriptor_type = vk.descriptor_type_storage_image,
                .descriptor_count = 1,
                .stage_flags = vk.shader_stage_compute_bit,
            };
        }
        descriptor_bindings[2 + maximum_storage_images] = .{
            .binding = dynamic_scalar_descriptor_binding,
            .descriptor_type = vk.descriptor_type_storage_buffer,
            .descriptor_count = 1,
            .stage_flags = vk.shader_stage_vertex_bit | vk.shader_stage_fragment_bit,
        };
        descriptor_bindings[3 + maximum_storage_images] = .{
            .binding = sampled_image_3d_descriptor_binding,
            .descriptor_type = vk.descriptor_type_combined_image_sampler,
            .descriptor_count = maximum_storage_descriptors,
            .stage_flags = vk.shader_stage_fragment_bit | vk.shader_stage_compute_bit,
        };
        const descriptor_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = descriptor_bindings.len,
            .bindings = &descriptor_bindings,
        };
        var descriptor_set_layout: vk.DescriptorSetLayout = 0;
        if (device_functions.create_descriptor_set_layout(device, &descriptor_layout_info, null, &descriptor_set_layout) != vk.success) {
            return Error.DescriptorSetLayoutCreationFailed;
        }
        errdefer device_functions.destroy_descriptor_set_layout(device, descriptor_set_layout, null);

        const pool_size = vk.DescriptorPoolSize{
            .descriptor_type = vk.descriptor_type_storage_buffer,
            .descriptor_count = maximum_storage_descriptors + 1,
        };
        const image_pool_size = vk.DescriptorPoolSize{
            .descriptor_type = vk.descriptor_type_combined_image_sampler,
            .descriptor_count = maximum_storage_descriptors * 2,
        };
        const storage_image_pool_size = vk.DescriptorPoolSize{
            .descriptor_type = vk.descriptor_type_storage_image,
            .descriptor_count = maximum_storage_images,
        };
        const pool_sizes = [_]vk.DescriptorPoolSize{ pool_size, image_pool_size, storage_image_pool_size };
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .max_sets = 1,
            .pool_size_count = pool_sizes.len,
            .pool_sizes = &pool_sizes,
        };
        var descriptor_pool: vk.DescriptorPool = 0;
        if (device_functions.create_descriptor_pool(device, &descriptor_pool_info, null, &descriptor_pool) != vk.success) {
            return Error.DescriptorPoolCreationFailed;
        }
        errdefer device_functions.destroy_descriptor_pool(device, descriptor_pool, null);

        const descriptor_allocate_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .set_layouts = @ptrCast(&descriptor_set_layout),
        };
        var descriptor_set: vk.DescriptorSet = 0;
        if (device_functions.allocate_descriptor_sets(device, &descriptor_allocate_info, @ptrCast(&descriptor_set)) != vk.success) {
            return Error.DescriptorSetAllocationFailed;
        }

        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .set_layouts = @ptrCast(&descriptor_set_layout),
        };
        var compute_pipeline_layout: vk.PipelineLayout = 0;
        if (device_functions.create_pipeline_layout(device, &pipeline_layout_info, null, &compute_pipeline_layout) != vk.success) {
            return Error.PipelineLayoutCreationFailed;
        }
        errdefer device_functions.destroy_pipeline_layout(device, compute_pipeline_layout, null);

        // The driver pipeline cache is reused across runs: a previous session's
        // compiled pipelines seed this one, so the first frames of a title do
        // not pay full driver compilation again. Stale or foreign cache bytes
        // are rejected by the driver; any failure falls back to an empty cache.
        const cached_bytes = loadPipelineCacheBytes(allocator);
        defer if (cached_bytes) |bytes| allocator.free(bytes);
        const pipeline_cache_info = vk.PipelineCacheCreateInfo{
            .initial_data_size = if (cached_bytes) |bytes| bytes.len else 0,
            .initial_data = if (cached_bytes) |bytes| bytes.ptr else null,
        };
        var driver_pipeline_cache: vk.PipelineCache = 0;
        if (device_functions.create_pipeline_cache(device, &pipeline_cache_info, null, &driver_pipeline_cache) != vk.success) {
            if (cached_bytes != null) {
                // Invalid payload (wrong driver/device): start over.
                const empty_info = vk.PipelineCacheCreateInfo{};
                if (device_functions.create_pipeline_cache(device, &empty_info, null, &driver_pipeline_cache) != vk.success) {
                    return Error.PipelineCacheCreationFailed;
                }
            } else {
                return Error.PipelineCacheCreationFailed;
            }
        }
        errdefer device_functions.destroy_pipeline_cache(device, driver_pipeline_cache, null);

        var memory_properties: vk.PhysicalDeviceMemoryProperties = undefined;
        instance_functions.get_memory_properties(candidate.physical_device, &memory_properties);

        const window_presentation: ?WindowPresentation = if (options.native_window) |window|
            try createWindowPresentation(
                allocator,
                candidate.physical_device,
                device,
                &device_functions,
                memory_properties,
                window,
                surface,
                surface_functions.?,
                swapchain_functions.?,
            )
        else
            null;
        errdefer if (window_presentation) |presentation| {
            swapchain_functions.?.destroy_swapchain(device, presentation.swapchain, null);
            allocator.free(presentation.images);
            device_functions.destroy_buffer(device, presentation.upload.handle, null);
            device_functions.free_memory(device, presentation.upload.memory, null);
            device_functions.destroy_fence(device, presentation.acquire_fence, null);
        };

        var renderer = Renderer{
            .allocator = allocator,
            .loader = loader,
            .instance_handle = instance_handle,
            .instance_functions = instance_functions,
            .physical_device = candidate.physical_device,
            .device = device,
            .device_functions = device_functions,
            .queue = queue,
            .queue_family_index = candidate.queue_family_index,
            .command_pool = command_pool,
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_pool = descriptor_pool,
            .descriptor_set = descriptor_set,
            .compute_pipeline_layout = compute_pipeline_layout,
            .driver_pipeline_cache = driver_pipeline_cache,
            .memory_properties = memory_properties,
            .loader_api_version = loader_api_version,
            .device_info = candidate.info,
            .validation_enabled = validation_enabled,
            .graphics_probe_enabled = options.enable_graphics_probe,
            .capture_first_graphics_frame = options.capture_first_graphics_frame,
            .force_probe_fragment = options.force_probe_fragment,
            .force_probe_fragment_texture = options.force_probe_fragment_texture,
            .force_probe_fragment_parameter = options.force_probe_fragment_parameter,
            .force_probe_fragment_ui = options.force_probe_fragment_ui,
            .skip_compute_dispatches = options.skip_compute_dispatches,
            .translate_compute_only = options.translate_compute_only,
            .window_presentation = window_presentation,
        };
        renderer.dynamic_scalar_buffer = try renderer.createBuffer(
            dynamic_scalar_buffer_bytes,
            vk.buffer_usage_storage_buffer_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        errdefer renderer.destroyBuffer(renderer.dynamic_scalar_buffer.?);
        var scalar_mapping: ?*anyopaque = null;
        if (device_functions.map_memory(
            device,
            renderer.dynamic_scalar_buffer.?.memory,
            0,
            dynamic_scalar_buffer_bytes,
            0,
            &scalar_mapping,
        ) != vk.success) return Error.MemoryMapFailed;
        renderer.dynamic_scalar_mapping = @ptrCast(@alignCast(scalar_mapping orelse return Error.MemoryMapFailed));
        errdefer device_functions.unmap_memory(device, renderer.dynamic_scalar_buffer.?.memory);

        const one_shot_fence_info = vk.FenceCreateInfo{};
        if (device_functions.create_fence(device, &one_shot_fence_info, null, &renderer.one_shot_fence) != vk.success) {
            return Error.FenceCreationFailed;
        }
        errdefer device_functions.destroy_fence(device, renderer.one_shot_fence, null);
        const one_shot_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = vk.command_buffer_level_primary,
            .command_buffer_count = 1,
        };
        var one_shot_command_buffer: vk.CommandBuffer = undefined;
        if (device_functions.allocate_command_buffers(
            device,
            &one_shot_allocate_info,
            @ptrCast(&one_shot_command_buffer),
        ) != vk.success) return Error.CommandBufferAllocationFailed;
        renderer.one_shot_command_buffer = one_shot_command_buffer;
        const scalar_buffer_info = vk.DescriptorBufferInfo{
            .buffer = renderer.dynamic_scalar_buffer.?.handle,
            .offset = 0,
            .range = dynamic_scalar_buffer_bytes,
        };
        const scalar_write = vk.WriteDescriptorSet{
            .destination_set = descriptor_set,
            .destination_binding = dynamic_scalar_descriptor_binding,
            .destination_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = vk.descriptor_type_storage_buffer,
            .buffer_info = @ptrCast(&scalar_buffer_info),
        };
        device_functions.update_descriptor_sets(device, 1, @ptrCast(&scalar_write), 0, null);
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.device_functions.device_wait_idle(self.device);
        self.pending_targetless_draws.deinit(self.allocator);
        for (self.render_targets.items) |target| self.destroyCachedRenderTarget(target);
        self.render_targets.deinit(self.allocator);
        for (self.depth_targets.items) |target| self.destroyCachedDepthTarget(target);
        self.depth_targets.deinit(self.allocator);
        self.htile_targets.deinit(self.allocator);
        for (self.sampled_image_cache.items) |image| {
            self.device_functions.destroy_sampler(self.device, image.sampler, null);
            self.device_functions.destroy_image_view(self.device, image.view, null);
            self.destroyImage(image.image);
        }
        self.sampled_image_cache.deinit(self.allocator);
        for (self.compute_pipelines.items) |entry| {
            self.device_functions.destroy_pipeline(self.device, entry.pipeline, null);
            self.device_functions.destroy_shader_module(self.device, entry.shader, null);
            self.allocator.free(entry.words);
        }
        self.compute_pipelines.deinit(self.allocator);
        for (self.graphics_pipelines.items) |entry| {
            self.device_functions.destroy_pipeline(self.device, entry.pipeline, null);
            self.allocator.free(entry.vertex_words);
            self.allocator.free(entry.fragment_words);
        }
        self.graphics_pipelines.deinit(self.allocator);
        for (self.analyzed_programs.items) |*entry| entry.analysis.deinit(self.allocator);
        self.analyzed_programs.deinit(self.allocator);
        for (self.completed_frames.items) |*frame| frame.pixels.deinit(self.allocator);
        self.completed_frames.deinit(self.allocator);
        self.guest_frame_scratch.deinit(self.allocator);
        for (self.guest_buffers.items) |entry| {
            self.destroyBuffer(entry.device_local);
        }
        self.guest_buffers.deinit(self.allocator);
        if (self.dynamic_scalar_buffer) |buffer| {
            if (self.dynamic_scalar_mapping != null) self.device_functions.unmap_memory(self.device, buffer.memory);
            self.destroyBuffer(buffer);
        }
        if (self.one_shot_fence != 0) self.device_functions.destroy_fence(self.device, self.one_shot_fence, null);
        self.gds_storage.deinit(self.allocator);
        // Persist compiled pipelines for the next run before the cache handle
        // is destroyed.
        savePipelineCacheBytes(self);
        self.device_functions.destroy_pipeline_cache(self.device, self.driver_pipeline_cache, null);
        self.device_functions.destroy_pipeline_layout(self.device, self.compute_pipeline_layout, null);
        self.device_functions.destroy_descriptor_pool(self.device, self.descriptor_pool, null);
        self.device_functions.destroy_descriptor_set_layout(self.device, self.descriptor_set_layout, null);
        self.device_functions.destroy_command_pool(self.device, self.command_pool, null);
        if (self.window_presentation) |presentation| {
            presentation.swapchain_functions.destroy_swapchain(self.device, presentation.swapchain, null);
            self.allocator.free(presentation.images);
            self.device_functions.destroy_buffer(self.device, presentation.upload.handle, null);
            self.device_functions.free_memory(self.device, presentation.upload.memory, null);
            self.device_functions.destroy_fence(self.device, presentation.acquire_fence, null);
            presentation.surface_functions.destroy_surface(self.instance_handle, presentation.surface, null);
        }
        self.device_functions.destroy_device(self.device, null);
        self.instance_functions.destroy_instance(self.instance_handle, null);
        self.loader.deinit();
        self.* = undefined;
    }

    /// Attaches the renderer to the existing DCB executor boundary. PM4 remains
    /// API-neutral; supported direct compute work is translated and submitted.
    /// Draws remain observable by default. Complete vertex/pixel programs are
    /// translated and submitted; the opt-in fixed-shader probe is only used
    /// when a draw has no guest graphics programs.
    pub fn dcbBackend(self: *Renderer, memory: GuestMemory) gpu.DcbBackend {
        self.guest_memory = memory;
        return .{ .context = self, .vtable = &dcb_vtable };
    }

    /// Installs the host consumer for completed `SetFlip` frames. The sink is
    /// invoked synchronously after all prior Vulkan work and guest target
    /// writeback have completed, so callers may copy or display `pixels`
    /// without owning Vulkan resources.
    pub fn setPresentationSink(self: *Renderer, sink: ?PresentationSink) void {
        self.presentation_sink = sink;
    }

    /// Installs an optional low-frequency FPS consumer. Updates are emitted
    /// once per measured second rather than once per frame.
    pub fn setFrameRateSink(self: *Renderer, sink: ?FrameRateSink) void {
        self.frame_rate_sink = sink;
        self.frame_rate_counter = .{};
    }

    /// Selects the registered display-buffer allocation named by a flip. With
    /// no resolver the most recently completed target is retained for isolated
    /// DCB tests.
    pub fn setDisplayBufferResolver(self: *Renderer, resolver: ?DisplayBufferResolver) void {
        self.display_buffer_resolver = resolver;
    }

    /// A sink that copies completed guest frames into the renderer-owned host
    /// swapchain. It is installed explicitly after `Renderer` reaches its final
    /// address because the callback context points back to this value.
    pub fn windowPresentationSink(self: *Renderer) ?PresentationSink {
        if (self.window_presentation == null) return null;
        return .{ .context = self, .present = presentWindowSink };
    }

    /// Presents one already-linear frame to the optional window swapchain.
    ///
    /// Batched present: the frame becomes the pending frame and is flushed
    /// unless a present is already running. A frame arriving during a flush
    /// replaces the pending one and is shown by the next flush, so a burst of
    /// eager presents and flips collapses to the latest frame instead of
    /// queuing one swapchain round-trip per draw.
    pub fn presentWindowFrame(self: *Renderer, frame: PresentedFrame) bool {
        self.pending_present = frame;
        return self.flushPendingPresent();
    }

    fn flushPendingPresent(self: *Renderer) bool {
        const frame = self.pending_present orelse return true;
        if (self.present_in_flight) return true;
        self.present_in_flight = true;
        defer self.present_in_flight = false;
        self.pending_present = null;
        self.copyFrameToSwapchain(frame) catch |err| {
            self.last_flip_error = err;
            return false;
        };
        return true;
    }

    fn presentWindowSink(context: ?*anyopaque, frame: PresentedFrame) bool {
        const self: *Renderer = @ptrCast(@alignCast(context orelse return false));
        return self.presentWindowFrame(frame);
    }

    fn copyFrameToSwapchain(self: *Renderer, frame: PresentedFrame) anyerror!void {
        const presentation = &(self.window_presentation orelse return Error.PresentationRejected);
        if (frame.width == 0 or frame.height == 0 or frame.row_pitch_bytes < frame.width * 4) {
            return Error.PresentationRejected;
        }
        const minimum_source_bytes = try std.math.add(
            usize,
            try std.math.mul(usize, frame.height - 1, frame.row_pitch_bytes),
            try std.math.mul(usize, frame.width, 4),
        );
        if (frame.pixels.len < minimum_source_bytes) return Error.PresentationRejected;
        const output_bytes_u64 = @as(u64, presentation.extent.width) * presentation.extent.height * 4;
        const output_bytes = std.math.cast(usize, output_bytes_u64) orelse return Error.PresentationRejected;
        if (output_bytes == 0 or output_bytes > maximum_frame_bytes) return Error.PresentationRejected;

        const upload = &presentation.upload;
        if (output_bytes > upload.size) return Error.PresentationRejected;
        var mapped: ?*anyopaque = null;
        if (self.device_functions.map_memory(self.device, upload.memory, 0, output_bytes, 0, &mapped) != vk.success) {
            return Error.MemoryMapFailed;
        }
        const output: [*]u8 = @ptrCast(mapped orelse {
            self.device_functions.unmap_memory(self.device, upload.memory);
            return Error.MemoryMapFailed;
        });
        scalePresentedFrame(
            output[0..output_bytes],
            presentation.extent.width,
            presentation.extent.height,
            presentation.format,
            frame,
        );
        self.device_functions.unmap_memory(self.device, upload.memory);

        // Non-blocking acquire: a swapchain with no free image drops this
        // frame (the pending queue already holds a newer one). Waiting here is
        // what used to stall the emulator's frame pacing on the display rate.
        if (self.device_functions.reset_fences(self.device, 1, @ptrCast(&presentation.acquire_fence)) != vk.success) {
            return Error.FenceWaitFailed;
        }
        var image_index: u32 = 0;
        const acquired = presentation.swapchain_functions.acquire_next_image(
            self.device,
            presentation.swapchain,
            0,
            0,
            presentation.acquire_fence,
            &image_index,
        );
        if (acquired == vk.not_ready or acquired == vk.error_out_of_date_khr) {
            // Frame dropped, not an error: the swapchain is still showing the
            // previous frame and a newer one will replace this one.
            self.present_dropped += 1;
            return;
        }
        if (acquired != vk.success and acquired != vk.suboptimal_khr) return Error.SwapchainAcquireFailed;
        if (image_index >= presentation.images.len or
            self.device_functions.wait_for_fences(self.device, 1, @ptrCast(&presentation.acquire_fence), vk.true_value, std.math.maxInt(u64)) != vk.success)
        {
            return Error.FenceWaitFailed;
        }

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const upload_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = 0,
            .destination_access_mask = vk.access_transfer_write_bit,
            .old_layout = vk.image_layout_undefined,
            .new_layout = vk.image_layout_transfer_dst_optimal,
            .image = presentation.images[image_index],
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_top_of_pipe_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&upload_barrier),
        );
        const copy = vk.BufferImageCopy{
            .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .image_extent = .{ .width = presentation.extent.width, .height = presentation.extent.height, .depth = 1 },
        };
        self.device_functions.cmd_copy_buffer_to_image(
            command_buffer,
            upload.handle,
            presentation.images[image_index],
            vk.image_layout_transfer_dst_optimal,
            1,
            @ptrCast(&copy),
        );
        const present_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = 0,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_present_src_khr,
            .image = presentation.images[image_index],
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_bottom_of_pipe_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&present_barrier),
        );
        try self.submitOneShot(command_buffer);

        const present_info = vk.PresentInfoKHR{
            .swapchain_count = 1,
            .swapchains = @ptrCast(&presentation.swapchain),
            .image_indices = @ptrCast(&image_index),
        };
        const presented = presentation.swapchain_functions.queue_present(self.queue, &present_info);
        if (presented != vk.success and presented != vk.suboptimal_khr) return Error.SwapchainPresentFailed;
    }

    /// Presents a resident color attachment without a GPU→CPU→GPU round trip.
    /// Vulkan performs format conversion and 1920×1080→window scaling in the
    /// blit; the source returns to attachment layout for the next guest draw.
    fn blitRenderTargetToSwapchain(self: *Renderer, target_index: usize) anyerror!void {
        if (target_index >= self.render_targets.items.len) return Error.MissingPresentedFrame;
        try self.transitionRenderTargetToColorAttachment(target_index);
        const target = self.render_targets.items[target_index];
        if (!target.initialized) return Error.MissingPresentedFrame;
        const presentation = &(self.window_presentation orelse return Error.PresentationRejected);

        if (self.device_functions.reset_fences(self.device, 1, @ptrCast(&presentation.acquire_fence)) != vk.success) {
            return Error.FenceWaitFailed;
        }
        var image_index: u32 = 0;
        const acquired = presentation.swapchain_functions.acquire_next_image(
            self.device,
            presentation.swapchain,
            0,
            0,
            presentation.acquire_fence,
            &image_index,
        );
        if (acquired == vk.not_ready or acquired == vk.error_out_of_date_khr) {
            self.present_dropped += 1;
            return;
        }
        if (acquired != vk.success and acquired != vk.suboptimal_khr) return Error.SwapchainAcquireFailed;
        if (image_index >= presentation.images.len or
            self.device_functions.wait_for_fences(self.device, 1, @ptrCast(&presentation.acquire_fence), vk.true_value, std.math.maxInt(u64)) != vk.success)
        {
            return Error.FenceWaitFailed;
        }

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const source_to_transfer = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .old_layout = vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_transfer_src_optimal,
            .image = target.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        const destination_to_transfer = vk.ImageMemoryBarrier{
            .source_access_mask = 0,
            .destination_access_mask = vk.access_transfer_write_bit,
            .old_layout = vk.image_layout_undefined,
            .new_layout = vk.image_layout_transfer_dst_optimal,
            .image = presentation.images[image_index],
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        const before_blit = [_]vk.ImageMemoryBarrier{ source_to_transfer, destination_to_transfer };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_color_attachment_output_bit | vk.pipeline_stage_top_of_pipe_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            before_blit.len,
            @ptrCast(&before_blit),
        );
        const blit = vk.ImageBlit{
            .source_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .source_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{ .x = @intCast(target.target.descriptor.width), .y = @intCast(target.target.descriptor.height), .z = 1 },
            },
            .destination_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .destination_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{ .x = @intCast(presentation.extent.width), .y = @intCast(presentation.extent.height), .z = 1 },
            },
        };
        self.device_functions.cmd_blit_image(
            command_buffer,
            target.image.handle,
            vk.image_layout_transfer_src_optimal,
            presentation.images[image_index],
            vk.image_layout_transfer_dst_optimal,
            1,
            @ptrCast(&blit),
            vk.filter_nearest,
        );
        const source_to_attachment = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_read_bit,
            .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .old_layout = vk.image_layout_transfer_src_optimal,
            .new_layout = vk.image_layout_color_attachment_optimal,
            .image = target.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        const destination_to_present = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = 0,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_present_src_khr,
            .image = presentation.images[image_index],
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        const after_blit = [_]vk.ImageMemoryBarrier{ source_to_attachment, destination_to_present };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_color_attachment_output_bit | vk.pipeline_stage_bottom_of_pipe_bit,
            0,
            0,
            null,
            0,
            null,
            after_blit.len,
            @ptrCast(&after_blit),
        );
        try self.submitOneShot(command_buffer);

        const present_info = vk.PresentInfoKHR{
            .swapchain_count = 1,
            .swapchains = @ptrCast(&presentation.swapchain),
            .image_indices = @ptrCast(&image_index),
        };
        const presented = presentation.swapchain_functions.queue_present(self.queue, &present_info);
        if (presented != vk.success and presented != vk.suboptimal_khr) return Error.SwapchainPresentFailed;
    }

    /// Reuses host/device allocations for an exact guest range. Guest-authored
    /// buffers upload current bytes; large GPU-authored outputs stay resident
    /// until a consumer explicitly needs guest-visible data.
    pub fn stageGuestStorageBuffer(self: *Renderer, guest_address: u64, size: usize) (Error || std.mem.Allocator.Error)!StagedBuffer {
        return self.stageGuestStorageBufferAt(0, guest_address, size);
    }

    /// Uploads one exact guest range and publishes it at a stable element of
    /// set 0 / binding 0. Descriptor-array identity is independent from the
    /// allocation cache, so slots can be rebound between dispatches.
    pub fn stageGuestStorageBufferAt(
        self: *Renderer,
        descriptor_index: u32,
        guest_address: u64,
        size: usize,
    ) (Error || std.mem.Allocator.Error)!StagedBuffer {
        const profile_started = hostTimestampNs();
        defer self.frame_profile.storage_stage_ns +|= elapsedHostNanoseconds(profile_started);
        if (descriptor_index >= maximum_storage_descriptors) return Error.InvalidStorageDescriptor;
        if (size == 0) return Error.GuestMemoryReadFailed;
        if (size > maximum_staged_buffer_bytes) return Error.GuestBufferTooLarge;
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        self.guest_buffer_sequence +%= 1;

        var entry_index: ?usize = null;
        for (self.guest_buffers.items, 0..) |entry, index| {
            if (entry.guest_address == guest_address and entry.size == size) {
                entry_index = index;
                break;
            }
        }
        const cache_hit = entry_index != null;
        if (entry_index == null) {
            // Each descriptor slot owns at most one backing allocation. Guest
            // ring addresses change constantly, but rebinding slot N does not
            // require retaining every address slot N used in prior frames.
            var recycle_index: ?usize = null;
            for (self.guest_buffers.items, 0..) |entry, index| {
                if (entry.descriptor_index == descriptor_index) {
                    recycle_index = index;
                    break;
                }
            }
            // Do not evict a GPU-authored range merely because the next shader
            // binds this descriptor slot to another address. Descriptor-array
            // slots do not own cache allocations: keep the dirty range by
            // address and recycle an old clean allocation first. Unity clears
            // several buffers through the same UAV slot before consuming them;
            // flushing the previous slot owner here otherwise turns a resident
            // render target into a full device -> guest -> device round trip.
            if (recycle_index) |index| {
                if (self.guest_buffers.items[index].gpu_dirty) {
                    recycle_index = null;
                    if (self.guest_buffers.items.len >= maximum_guest_buffers) {
                        var oldest_clean: u64 = std.math.maxInt(u64);
                        for (self.guest_buffers.items, 0..) |entry, candidate_index| {
                            if (!entry.gpu_dirty and entry.last_used_sequence < oldest_clean) {
                                oldest_clean = entry.last_used_sequence;
                                recycle_index = candidate_index;
                            }
                        }
                    }
                }
            }
            if (recycle_index == null and self.guest_buffers.items.len >= maximum_guest_buffers) {
                var oldest_index: usize = 0;
                var oldest: u64 = std.math.maxInt(u64);
                for (self.guest_buffers.items, 0..) |entry, index| {
                    if (entry.last_used_sequence < oldest) {
                        oldest = entry.last_used_sequence;
                        oldest_index = index;
                    }
                }
                recycle_index = oldest_index;
            }

            if (recycle_index == null) {
                try self.guest_buffers.ensureUnusedCapacity(self.allocator, 1);
                const device_local = try self.createBuffer(
                    size,
                    vk.buffer_usage_storage_buffer_bit,
                    vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
                );
                errdefer self.destroyBuffer(device_local);
                self.guest_buffers.appendAssumeCapacity(.{
                    .descriptor_index = descriptor_index,
                    .guest_address = guest_address,
                    .size = size,
                    .device_local = device_local,
                    .last_used_sequence = self.guest_buffer_sequence,
                });
                entry_index = self.guest_buffers.items.len - 1;
            } else {
                // Every submission using these buffers has completed before
                // this point. Recycle the least-recent range instead of
                // dropping later geometry once the guest ring has wrapped.
                const victim_index = recycle_index.?;
                if (self.guest_buffers.items[victim_index].gpu_dirty) {
                    try self.flushGuestStorageBuffer(victim_index);
                }
                const victim = &self.guest_buffers.items[victim_index];
                if (victim.device_local.size < size) {
                    const replacement_device = try self.createBuffer(
                        size,
                        vk.buffer_usage_storage_buffer_bit,
                        vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
                    );
                    errdefer self.destroyBuffer(replacement_device);
                    self.destroyBuffer(victim.device_local);
                    victim.device_local = replacement_device;
                }
                victim.descriptor_index = descriptor_index;
                victim.guest_address = guest_address;
                victim.size = size;
                victim.last_used_sequence = self.guest_buffer_sequence;
                victim.gpu_dirty = false;
                entry_index = victim_index;
            }
            self.buffer_cache_misses += 1;
        } else {
            self.buffer_cache_hits += 1;
        }

        const entry = &self.guest_buffers.items[entry_index.?];
        entry.last_used_sequence = self.guest_buffer_sequence;
        if (!entry.gpu_dirty) {
            var mapped: ?*anyopaque = null;
            if (self.device_functions.map_memory(self.device, entry.device_local.memory, 0, size, 0, &mapped) != vk.success) {
                return Error.MemoryMapFailed;
            }
            const destination: [*]u8 = @ptrCast(mapped orelse {
                self.device_functions.unmap_memory(self.device, entry.device_local.memory);
                return Error.MemoryMapFailed;
            });
            const read_ok = memory.read(memory.context, guest_address, destination[0..size]);
            self.device_functions.unmap_memory(self.device, entry.device_local.memory);
            if (!read_ok) return Error.GuestMemoryReadFailed;
            self.frame_profile.upload_bytes +%= size;
            self.frame_profile.storage_upload_bytes +%= size;
            self.buffer_uploads += 1;
        } else {
            self.frame_profile.resident_storage_bytes +%= size;
        }
        self.updateStorageDescriptor(descriptor_index, entry.device_local);
        self.active_descriptor_set = self.descriptor_set;
        return .{
            .buffer = entry.device_local.handle,
            .descriptor_set = self.descriptor_set,
            .descriptor_index = descriptor_index,
            .size = entry.size,
            .allocation_cache_hit = cache_hit,
        };
    }

    pub fn readbackGuestStorageBuffer(self: *Renderer, guest_address: u64, destination: []u8) Error!void {
        const entry = for (self.guest_buffers.items) |*candidate| {
            if (candidate.guest_address == guest_address and candidate.size == destination.len) break candidate;
        } else return Error.GuestBufferNotStaged;
        try self.readMapped(entry.device_local, destination);
        self.frame_profile.readback_bytes +%= destination.len;
        self.frame_profile.storage_readback_bytes +%= destination.len;
    }

    fn flushGuestStoragePrefix(self: *Renderer, index: usize, requested_size: usize) (Error || std.mem.Allocator.Error)!void {
        if (index >= self.guest_buffers.items.len) return Error.GuestBufferNotStaged;
        const entry = &self.guest_buffers.items[index];
        if (!entry.gpu_dirty) return;
        const entry_size = std.math.cast(usize, entry.size) orelse return Error.GuestBufferTooLarge;
        const size = @min(requested_size, entry_size);
        if (size == 0) return;
        const bytes = try self.allocator.alloc(u8, size);
        defer self.allocator.free(bytes);
        try self.readMapped(entry.device_local, bytes);
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        if (!memory.write(memory.context, entry.guest_address, bytes)) return Error.GuestMemoryWriteFailed;
        self.frame_profile.readback_bytes +%= size;
        self.frame_profile.storage_readback_bytes +%= size;
        if (size == entry_size) entry.gpu_dirty = false;
    }

    fn flushGuestStorageBuffer(self: *Renderer, index: usize) (Error || std.mem.Allocator.Error)!void {
        return self.flushGuestStoragePrefix(index, std.math.maxInt(usize));
    }

    fn flushGuestStorageRange(self: *Renderer, address: u64, size: usize) (Error || std.mem.Allocator.Error)!void {
        for (self.guest_buffers.items, 0..) |entry, index| {
            if (!entry.gpu_dirty) continue;
            // Guest V# record counts are occasionally conservative enough to
            // span unrelated fence/label allocations. A four-byte command
            // processor access inside that declared range is not evidence that
            // the CPU is reading the compute output. Materialize only a read
            // that names the resource itself; sampled-image and presentation
            // paths also use the exact base address.
            if (address == entry.guest_address) try self.flushGuestStoragePrefix(index, size);
        }
    }

    pub fn dispatchSpirv(self: *Renderer, words: []const u32, group_count: [3]u32) (Error || std.mem.Allocator.Error)!DispatchReport {
        const lookup = try self.getComputePipeline(words);
        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        self.device_functions.cmd_bind_pipeline(command_buffer, vk.pipeline_bind_point_compute, lookup.pipeline);
        if (self.active_descriptor_set) |descriptor_set| {
            self.device_functions.cmd_bind_descriptor_sets(
                command_buffer,
                vk.pipeline_bind_point_compute,
                self.compute_pipeline_layout,
                0,
                1,
                @ptrCast(&descriptor_set),
                0,
                null,
            );
        }
        self.device_functions.cmd_dispatch(command_buffer, group_count[0], group_count[1], group_count[2]);
        try self.submitOneShot(command_buffer);
        return .{
            .pipeline_cache_hit = lookup.cache_hit,
            .group_count = group_count,
            .spirv_words = words.len,
        };
    }

    pub fn dispatchRdna2Address(
        self: *Renderer,
        program_address: u64,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!DispatchReport {
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
        const analysis = try self.analyzedProgram(reader, program_address);
        var module = try analysis.translateSpirv(self.allocator, .{ .stage = .compute, .local_size = local_size });
        defer module.deinit(self.allocator);
        return self.dispatchSpirv(module.words, group_count);
    }

    /// Captures compute user data and AGC resource metadata at the DCB boundary,
    /// stages every declared buffer table entry into the fixed Vulkan array,
    /// maps each executable MUBUF V# to its array element, then writes modified
    /// storage ranges back to guest memory after the synchronous submission.
    pub fn dispatchRdna2State(
        self: *Renderer,
        state: *const gpu.State,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!DispatchReport {
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
        const program_address = gpu.resources.ShaderStage.compute.programAddress(state) orelse {
            return Error.MissingComputeProgram;
        };
        const header_address = if (memory.shader_header) |resolve|
            resolve(memory.context, program_address)
        else
            null;
        const bindings = try gpu.ShaderBindings.capture(state, .compute, header_address, reader);
        const system_registers = gpu.resources.decodeComputeSystemRegisters(state);
        const analysis = try self.analyzedProgram(reader, program_address);
        if (try self.tryEmulateGdsInitialization(
            memory,
            state,
            analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateBufferCopy(
            memory,
            state,
            analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulatePackedColorBufferClear(
            state,
            analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateImageStoreClear(
            memory,
            &bindings,
            reader,
            analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateImageCopy(
            memory,
            &bindings,
            reader,
            analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateVolumeBufferCopy(
            memory,
            &bindings,
            reader,
            analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (!analysis.hasExternalEffects()) {
            self.elided_dispatches += 1;
            std.debug.print(
                "[vulkan dcb] elided side-effect-free compute program 0x{x} ({d} instructions, groups={d}x{d}x{d})\n",
                .{
                    program_address,
                    analysis.program.instructions.items.len,
                    group_count[0],
                    group_count[1],
                    group_count[2],
                },
            );
            return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
        }
        const specialized_scalar_prefix_end = scalarPrefixEnd(analysis);
        const scalar = gpu.scalar_provenance.evaluatePrefixUntil(reader, &bindings, specialized_scalar_prefix_end);
        var resources = try self.prepareComputeResources(
            &bindings,
            reader,
            analysis,
            &scalar,
            specialized_scalar_prefix_end,
            null,
        );
        defer resources.deinit(self);
        if (self.flip_callbacks == 240) {
            std.debug.print(
                "[vulkan dcb] traced compute resources dispatch={d} program=0x{x} buffers={d} sampled={d} storage_images={d}\n",
                .{
                    self.frame_profile.dispatches,
                    program_address,
                    resources.mapping_count,
                    resources.sampled_image_mapping_count,
                    resources.storage_image_mapping_count,
                },
            );
            for (resources.mappings[0..resources.mapping_count]) |mapping| {
                const slot: usize = @intCast(mapping.descriptor_index);
                std.debug.print(
                    "  traced buffer slot={d} V#s{d} addr=0x{x} size=0x{x} stride={d} fmt={d} writable={any}\n",
                    .{
                        mapping.descriptor_index,
                        mapping.resource_sgpr,
                        resources.addresses[slot],
                        resources.sizes[slot],
                        mapping.stride,
                        mapping.unified_format,
                        resources.writable[slot],
                    },
                );
            }
            for (resources.storage_images[0..resources.storage_image_count], 0..) |image, index| {
                std.debug.print(
                    "  traced storage image slot={d} addr=0x{x} {d}x{d} fmt={d} writable={any}\n",
                    .{
                        index,
                        image.descriptor.address,
                        image.descriptor.width,
                        image.descriptor.height,
                        image.descriptor.unified_format,
                        image.writable,
                    },
                );
            }
            for (resources.sampled_images[0..resources.sampled_image_count], 0..) |_, index| {
                const sampled = resources.sampled_image_mappings[index];
                std.debug.print(
                    "  traced compute sampled slot={d} T#s{d} S#s{d} pc={any}\n",
                    .{ sampled.descriptor_index, sampled.resource_sgpr, sampled.sampler_sgpr, sampled.instruction_pc },
                );
            }
        }
        if (self.shouldReportComputeResources(program_address)) {
            std.debug.print(
                "[vulkan dcb] compute resources program=0x{x} groups={d}x{d}x{d} buffers={d} sampled={d} storage_images={d} scalars={d}\n",
                .{
                    program_address,
                    group_count[0],
                    group_count[1],
                    group_count[2],
                    resources.mapping_count,
                    resources.sampled_image_mapping_count,
                    resources.storage_image_mapping_count,
                    resources.scalar_count,
                },
            );
            for (resources.mappings[0..resources.mapping_count]) |mapping| {
                const slot: usize = @intCast(mapping.descriptor_index);
                std.debug.print(
                    "  buffer pc={any} V#s{d} slot={d} addr=0x{x} size=0x{x} writable={any}\n",
                    .{
                        mapping.instruction_pc,
                        mapping.resource_sgpr,
                        mapping.descriptor_index,
                        resources.addresses[slot],
                        resources.sizes[slot],
                        resources.writable[slot],
                    },
                );
            }
            for (resources.storage_images[0..resources.storage_image_count], 0..) |image, index| {
                std.debug.print(
                    "  storage image slot={d} addr=0x{x} {d}x{d}x{d} fmt={d} type={s} writable={any}\n",
                    .{
                        index,
                        image.descriptor.address,
                        image.descriptor.width,
                        image.descriptor.height,
                        image.descriptor.depth_or_layers,
                        image.descriptor.unified_format,
                        @tagName(image.descriptor.image_type),
                        image.writable,
                    },
                );
            }
            for (resources.sampled_image_mappings[0..resources.sampled_image_mapping_count]) |mapping| {
                std.debug.print(
                    "  sampled pc={any} T#s{d} S#s{d} slot={d}\n",
                    .{
                        mapping.instruction_pc,
                        mapping.resource_sgpr,
                        mapping.sampler_sgpr,
                        mapping.descriptor_index,
                    },
                );
            }
            dumpScalarRegisters(resources.scalar_registers[0..resources.scalar_count]);
            dumpShaderHead(analysis, 48);
        }
        var module = analysis.translateSpirv(self.allocator, .{
            .stage = .compute,
            .local_size = local_size,
            .storage_buffers = resources.mappings[0..resources.mapping_count],
            .sampled_images = resources.sampled_image_mappings[0..resources.sampled_image_mapping_count],
            .storage_images = resources.storage_image_mappings[0..resources.storage_image_mapping_count],
            .scalar_registers = resources.scalar_registers[0..resources.scalar_count],
            .compute_inputs = .{
                .workgroup_id_sgprs = system_registers.workgroup_id_sgprs,
                .threadgroup_size_sgpr = system_registers.threadgroup_size_sgpr,
                .local_invocation_id_components = system_registers.local_invocation_id_components,
            },
            .workgroup_memory_size_bytes = computeLdsSizeBytes(state),
            .descriptor_array_length = maximum_storage_descriptors,
            .specialized_scalar_prefix_end = resources.specialized_scalar_prefix_end,
        }) catch |err| {
            if (self.shouldReportComputeShaderFailure(program_address, err)) {
                std.debug.print(
                    "[vulkan dcb] compute program 0x{x}: {d} instructions, groups={d}x{d}x{d}, local={d}x{d}x{d}, rsrc2=0x{x}\n",
                    .{
                        program_address,
                        analysis.program.instructions.items.len,
                        group_count[0],
                        group_count[1],
                        group_count[2],
                        local_size[0],
                        local_size[1],
                        local_size[2],
                        state.readRegister(.shader, 0x213) orelse 0,
                    },
                );
                std.debug.print("[vulkan dcb] Translation error: {s}\n", .{@errorName(err)});
                // Unique small kernels are cheap and useful to print in full;
                // large programs stay capped. Repeated failures are suppressed
                // by address/error above, avoiding per-frame disassembly spam.
                const dump_limit: usize = if (analysis.program.instructions.items.len <= 64) 64 else 12;
                var printed: usize = 0;
                for (analysis.program.instructions.items) |inst| {
                    if (printed >= dump_limit) {
                        std.debug.print("  ... ({d} more instructions)\n", .{
                            analysis.program.instructions.items.len - printed,
                        });
                        break;
                    }
                    std.debug.print(
                        "  pc=0x{x:0>4} {s} dst={s}:{d} src=",
                        .{ inst.pc, inst.opcode.mnemonic(), @tagName(inst.dst.kind), inst.dst.reg },
                    );
                    const sources = inst.sources();
                    for (sources.slice()) |source| {
                        const source_value = switch (source.kind) {
                            .sgpr, .vgpr => source.reg,
                            else => source.value,
                        };
                        std.debug.print(" {s}:{d}", .{ @tagName(source.kind), source_value });
                    }
                    std.debug.print(
                        " off={d} idx={d} offen={d} opid=0x{x}\n",
                        .{ inst.memory_offset, @intFromBool(inst.index_enable), @intFromBool(inst.offset_enable), inst.opcode_id },
                    );
                    printed += 1;
                }
            }
            return err;
        };
        defer module.deinit(self.allocator);
        if (self.translate_compute_only) {
            std.debug.print(
                "[vulkan dcb] compute translated only: program=0x{x} spirv_words={d} groups={d}x{d}x{d}\n",
                .{
                    program_address,
                    module.words.len,
                    group_count[0],
                    group_count[1],
                    group_count[2],
                },
            );
            return .{
                .pipeline_cache_hit = false,
                .group_count = group_count,
                .spirv_words = module.words.len,
            };
        }
        const report = try self.dispatchSpirv(module.words, group_count);
        try self.commitComputeWrites(memory, &resources);
        try self.commitStorageImages(memory, &resources);
        return report;
    }

    fn tryEmulateGdsInitialization(
        self: *Renderer,
        memory: GuestMemory,
        state: *const gpu.State,
        analysis: *const gpu.ShaderAnalysis,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        const inst = analysis.program.instructions.items;
        if (inst.len != 14 or
            inst[0].opcode != .s_inst_prefetch or
            inst[1].opcode != .v_lshl_add_u32 or
            inst[2].opcode != .s_buffer_load_dword or
            inst[3].opcode != .s_waitcnt or
            inst[4].opcode != .v_cmpx_gt_u32 or
            inst[5].opcode != .s_cbranch_execz or
            inst[6].opcode != .buffer_load_format_x or
            inst[7].opcode != .s_buffer_load_dword or
            inst[8].opcode != .s_waitcnt or
            inst[9].opcode != .v_mov_b32 or
            inst[10].opcode != .s_bfm_b32 or
            inst[11].opcode != .s_waitcnt or
            inst[12].opcode != .ds_write_b32 or
            inst[13].opcode != .s_endpgm)
        {
            return null;
        }
        if (local_size[0] != 64 or local_size[1] != 1 or local_size[2] != 1 or
            group_count[1] != 1 or group_count[2] != 1 or
            system.workgroup_id_sgprs[0] != 8 or
            system.workgroup_id_sgprs[1] != null or system.workgroup_id_sgprs[2] != null or
            system.local_invocation_id_components != 1)
        {
            return null;
        }
        if (!registerOperand(inst[1].dst, .vgpr, 0) or
            !registerOperand(inst[1].src0, .sgpr, 8) or
            inst[1].src1.kind != .integer_inline_constant or inst[1].src1.value != 6 or
            !registerOperand(inst[1].src2, .vgpr, 0) or
            inst[2].dst.kind != .vcc_lo or !registerOperand(inst[2].src0, .sgpr, 4) or inst[2].memory_offset != 0 or
            inst[4].dst.kind != .exec_lo or inst[4].src0.kind != .vcc_lo or !registerOperand(inst[4].src1, .vgpr, 0) or
            !registerOperand(inst[6].dst, .vgpr, 0) or !registerOperand(inst[6].src0, .vgpr, 0) or
            !registerOperand(inst[6].src1, .sgpr, 0) or !inst[6].index_enable or inst[6].offset_enable or
            inst[7].dst.kind != .vcc_lo or !registerOperand(inst[7].src0, .sgpr, 4) or inst[7].memory_offset != 4 or
            !registerOperand(inst[9].dst, .vgpr, 1) or inst[9].src0.kind != .vcc_lo or
            inst[10].dst.kind != .m0 or inst[10].src0.value != 2 or inst[10].src1.value != 14 or
            !inst[12].gds or !registerOperand(inst[12].src0, .vgpr, 0) or !registerOperand(inst[12].src1, .vgpr, 1))
        {
            return null;
        }

        const addresses = try descriptorFromComputeUserData(state, 0);
        const control = try descriptorFromComputeUserData(state, 4);
        if (addresses.stride != 4 or addresses.swizzle_enabled or addresses.add_thread_id or
            addresses.out_of_bounds_select != 0 or addresses.unified_format != 20 or
            addresses.dst_select[0] != 4 or control.address == 0 or control.size_bytes < 8)
        {
            return null;
        }

        const element_count = try readGuestU32(memory, control.address);
        const fill_value = try readGuestU32(memory, control.address + 4);
        const dispatched = std.math.mul(u64, group_count[0], local_size[0]) catch return Error.GuestBufferTooLarge;
        const source_records = if (addresses.stride == 0)
            @as(u64, addresses.record_count)
        else
            addresses.size_bytes / addresses.stride;
        const writes: usize = @intCast(@min(@as(u64, element_count), @min(dispatched, source_records)));

        const gds_bytes: usize = 64 * 1024;
        if (self.gds_storage.items.len == 0) {
            try self.gds_storage.resize(self.allocator, gds_bytes);
            @memset(self.gds_storage.items, 0);
        }
        var address_bytes: [4]u8 = undefined;
        var value_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &value_bytes, fill_value, .little);
        for (0..writes) |index| {
            const guest_address = addresses.address + @as(u64, @intCast(index)) * addresses.stride;
            if (!memory.read(memory.context, guest_address, &address_bytes)) return Error.GuestMemoryReadFailed;
            const gds_address: usize = @intCast(std.mem.readInt(u32, &address_bytes, .little) & ~@as(u32, 3));
            if (gds_address > self.gds_storage.items.len or 4 > self.gds_storage.items.len - gds_address) {
                return Error.InvalidStorageDescriptor;
            }
            @memcpy(self.gds_storage.items[gds_address..][0..4], &value_bytes);
        }
        self.emulated_gds_dispatches += 1;
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] emulated GDS initialization: {d} writes, value=0x{x}\n",
            .{ writes, fill_value },
        );
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    /// Executes Unity's full-surface 2D image copy without round-tripping two
    /// eight-megabyte tiled images through temporary Vulkan resources.  The
    /// matched kernel only changes the allocation address: source and target
    /// use the same format, dimensions and tile equation, so their guest
    /// payloads are byte-for-byte compatible after the resident source target
    /// has been materialized.
    fn tryEmulateImageCopy(
        self: *Renderer,
        memory: GuestMemory,
        bindings: *const gpu.ShaderBindings,
        reader: gpu.ShaderMemoryReader,
        analysis: *const gpu.ShaderAnalysis,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        const instructions = analysis.program.instructions.items;
        if (!matchesWholeImageCopy(instructions) or
            local_size[0] != 8 or local_size[1] != 8 or local_size[2] != 1)
        {
            return null;
        }
        _ = system;

        const source = (try bindings.inlineImageDescriptor(0)) orelse return null;
        const destination = try imageDescriptorFromUserDataPointer(bindings, reader, 12) orelse return null;
        const control = (try bindings.inlineBufferDescriptor(8)) orelse return null;
        if (control.address == 0 or control.size_bytes < 24 or
            source.address == 0 or destination.address == 0 or source.address == destination.address or
            source.image_type != .color_2d or destination.image_type != .color_2d or
            source.width != destination.width or source.height != destination.height or
            source.depth_or_layers != 1 or destination.depth_or_layers != 1 or
            source.pitch != destination.pitch or source.unified_format != destination.unified_format or
            source.tile_mode != destination.tile_mode or source.samplesLog2() != 0 or
            destination.samplesLog2() != 0 or source.viewBaseLevel() != 0 or
            destination.viewBaseLevel() != 0 or source.viewMipLevels() != 1 or
            destination.viewMipLevels() != 1 or source.dcc_enabled or destination.dcc_enabled or
            source.cmask_fast_clear or destination.cmask_fast_clear or
            source.fmask_compression or destination.fmask_compression)
        {
            return null;
        }

        const bounds_offset = std.math.cast(u64, instructions[2].memory_offset) orelse return null;
        const source_offset = std.math.cast(u64, instructions[9].memory_offset) orelse return null;
        const destination_offset = std.math.cast(u64, instructions[13].memory_offset) orelse return null;
        const last_control_byte = @max(bounds_offset, @max(source_offset, destination_offset)) + 8;
        if (last_control_byte > control.size_bytes) return null;
        const copy_width = try readGuestU32(memory, control.address + bounds_offset);
        const copy_height = try readGuestU32(memory, control.address + bounds_offset + 4);
        const source_x = try readGuestU32(memory, control.address + source_offset);
        const source_y = try readGuestU32(memory, control.address + source_offset + 4);
        const destination_x = try readGuestU32(memory, control.address + destination_offset);
        const destination_y = try readGuestU32(memory, control.address + destination_offset + 4);
        const dispatched_width = std.math.mul(u64, group_count[0], local_size[0]) catch
            return Error.GuestBufferTooLarge;
        const dispatched_height = std.math.mul(u64, group_count[1], local_size[1]) catch
            return Error.GuestBufferTooLarge;
        if (copy_width != source.width or copy_height != source.height or
            source_x != 0 or source_y != 0 or destination_x != 0 or destination_y != 0 or
            dispatched_width < source.width or dispatched_height < source.height)
        {
            return null;
        }

        const source_layout = gpu.TextureLayout.fromImage(source) catch return null;
        const destination_layout = gpu.TextureLayout.fromImage(destination) catch return null;
        if (source_layout.required_source_bytes == 0 or
            source_layout.required_source_bytes != destination_layout.required_source_bytes or
            source_layout.required_source_bytes > maximum_frame_bytes)
        {
            return null;
        }
        const allocation_bytes = std.math.cast(usize, source_layout.required_source_bytes) orelse
            return Error.GuestBufferTooLarge;
        try self.flushPendingGuestWrite(source.address, allocation_bytes);
        const allocation = try self.allocator.alloc(u8, allocation_bytes);
        defer self.allocator.free(allocation);
        if (!memory.read(memory.context, source.address, allocation)) return Error.GuestMemoryReadFailed;
        if (!memory.write(memory.context, destination.address, allocation)) return Error.GuestMemoryWriteFailed;
        self.invalidateDmaDestination(destination.address, allocation_bytes);
        if (self.isVideoSurface(source.address)) self.markVideoSurface(destination.address);

        self.emulated_image_copy_dispatches += 1;
        if (log_verbose_gpu or self.emulated_image_copy_dispatches <= 4) {
            std.debug.print(
                "[vulkan dcb] emulated whole-image copy: 0x{x} -> 0x{x} {d}x{d} fmt={d} tile={s} bytes=0x{x} (#{d})\n",
                .{
                    source.address,
                    destination.address,
                    source.width,
                    source.height,
                    source.unified_format,
                    @tagName(source.tile_mode),
                    allocation_bytes,
                    self.emulated_image_copy_dispatches,
                },
            );
        }
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    fn tryEmulateBufferCopy(
        self: *Renderer,
        memory: GuestMemory,
        state: *const gpu.State,
        analysis: *const gpu.ShaderAnalysis,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        _ = system;

        const inst = analysis.program.instructions.items;
        if (inst.len != 14 or
            inst[0].opcode != .s_inst_prefetch or
            inst[1].opcode != .v_lshl_add_u32 or
            inst[2].opcode != .s_buffer_load_dword or
            inst[3].opcode != .s_waitcnt or
            inst[4].opcode != .v_cmpx_gt_u32 or
            inst[5].opcode != .s_cbranch_execz or
            inst[6].opcode != .s_buffer_load_dwordx2 or
            inst[7].opcode != .s_waitcnt or
            inst[8].opcode != .v_add_nc_u32 or
            inst[9].opcode != .v_add_nc_u32 or
            inst[10].opcode != .buffer_load_format_x or
            inst[11].opcode != .s_waitcnt or
            inst[12].opcode != .buffer_store_format_x or
            inst[13].opcode != .s_endpgm)
        {
            return null;
        }

        const source_desc = try descriptorFromComputeUserData(state, 0);
        const dest_desc = try descriptorFromComputeUserData(state, 4);
        const control = try descriptorFromComputeUserData(state, 8);
        if (control.address == 0) return null;

        const dest_offset = try readGuestU32(memory, control.address + 0);
        const src_offset = try readGuestU32(memory, control.address + 4);
        const element_count = try readGuestU32(memory, control.address + 8);

        const dispatched = std.math.mul(u64, group_count[0], local_size[0]) catch return Error.GuestBufferTooLarge;
        const copies: usize = @intCast(@min(@as(u64, element_count), dispatched));

        const src_stride = if (source_desc.stride == 0) 4 else source_desc.stride;
        const dest_stride = if (dest_desc.stride == 0) 4 else dest_desc.stride;

        for (0..copies) |i| {
            const value = try readGuestU32(memory, source_desc.address + (src_offset + i) * src_stride);
            try writeGuestU32(memory, dest_desc.address + (dest_offset + i) * dest_stride, value);
        }

        self.elided_dispatches += 1;
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] emulated buffer copy: {d} elements from 0x{x} to 0x{x}\n",
            .{ copies, source_desc.address, dest_desc.address },
        );
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    /// AGC clears an RGBA8 colour allocation through a formatted V# whose
    /// records each cover four packed pixels. Treating that allocation as a
    /// host-visible SSBO makes a fullscreen clear cross PCIe and also leaves
    /// the aliased Vulkan image stale. Match the complete seven-instruction
    /// kernel and clear the resident attachment directly instead.
    fn tryEmulatePackedColorBufferClear(
        self: *Renderer,
        state: *const gpu.State,
        analysis: *const gpu.ShaderAnalysis,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        const inst = analysis.program.instructions.items;
        if (inst.len != 7 or
            inst[0].opcode != .v_lshl_add_u32 or
            inst[1].opcode != .v_mov_b32 or
            inst[2].opcode != .v_mov_b32 or
            inst[3].opcode != .v_mov_b32 or
            inst[4].opcode != .v_mov_b32 or
            inst[5].opcode != .buffer_store_format_xyzw or
            inst[6].opcode != .s_endpgm)
        {
            return null;
        }
        if (local_size[0] != 64 or local_size[1] != 1 or local_size[2] != 1 or
            group_count[1] != 1 or group_count[2] != 1 or
            system.workgroup_id_sgprs[0] != 8 or
            system.workgroup_id_sgprs[1] != null or system.workgroup_id_sgprs[2] != null or
            system.local_invocation_id_components != 1 or
            !registerOperand(inst[0].dst, .vgpr, 4) or
            !registerOperand(inst[0].src0, .sgpr, 8) or
            inst[0].src1.kind != .integer_inline_constant or inst[0].src1.value != 6 or
            !registerOperand(inst[0].src2, .vgpr, 0))
        {
            return null;
        }
        for (inst[1..5], 0..) |move, index| {
            if (!registerOperand(move.dst, .vgpr, @intCast(index)) or
                !registerOperand(move.src0, .sgpr, @intCast(index + 4))) return null;
        }
        if (!registerOperand(inst[5].dst, .vgpr, 0) or
            !registerOperand(inst[5].src0, .vgpr, 4) or
            !registerOperand(inst[5].src1, .sgpr, 0) or
            inst[5].offset_enable or inst[5].memory_offset != 0)
        {
            return null;
        }

        const descriptor = try descriptorFromComputeUserData(state, 0);
        if (descriptor.address == 0 or descriptor.stride != 16 or descriptor.unified_format != 75 or
            descriptor.swizzle_enabled or descriptor.index_stride != 0 or descriptor.add_thread_id or
            descriptor.out_of_bounds_select != 0 or
            !std.mem.eql(u8, &descriptor.dst_select, &[_]u8{ 4, 5, 6, 7 }))
        {
            return null;
        }
        const dispatched = std.math.mul(u64, group_count[0], local_size[0]) catch
            return Error.GuestBufferTooLarge;
        if (dispatched != descriptor.record_count) return null;

        const packed_value = state.readRegister(.shader, 0x244) orelse return null;
        inline for (0x245..0x248) |register| {
            if ((state.readRegister(.shader, register) orelse return null) != packed_value) return null;
        }

        const render = gpu.resources.decodeRenderState(state);
        const target_descriptor = for (render.color_targets) |maybe_target| {
            const candidate = maybe_target orelse continue;
            if (candidate.isActive() and candidate.address == descriptor.address) break candidate;
        } else return null;
        if (target_descriptor.dcc_enabled or target_descriptor.cmask_fast_clear or
            target_descriptor.fmask_compression or target_descriptor.samples_log2 != 0 or
            target_descriptor.fragments_log2 != 0)
        {
            return null;
        }
        const format = colorTargetFormat(target_descriptor) orelse return null;
        if (format.vulkan != vk.format_r8g8b8a8_unorm or format.bytes_per_texel != 4) return null;
        const layout = try gpu.SurfaceLayout.fromColorTarget(target_descriptor);
        if (layout.required_source_bytes != descriptor.size_bytes or layout.layers != 1) return null;
        const target = GuestColorTarget{
            .descriptor = target_descriptor,
            .layout = layout,
            .format = format,
        };
        const target_index = try self.acquireRenderTarget(target);
        const snapshot = self.render_targets.items[target_index];

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const source_stage: vk.Flags = if (!snapshot.initialized)
            vk.pipeline_stage_top_of_pipe_bit
        else if (snapshot.shader_read_layout)
            vk.pipeline_stage_fragment_shader_bit | vk.pipeline_stage_compute_shader_bit
        else
            vk.pipeline_stage_color_attachment_output_bit;
        const to_transfer = vk.ImageMemoryBarrier{
            .source_access_mask = if (!snapshot.initialized)
                0
            else if (snapshot.shader_read_layout)
                vk.access_shader_read_bit
            else
                vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_transfer_write_bit,
            .old_layout = if (!snapshot.initialized)
                vk.image_layout_undefined
            else if (snapshot.shader_read_layout)
                vk.image_layout_shader_read_only_optimal
            else
                vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_transfer_dst_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            source_stage,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_transfer),
        );
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, packed_value, .little);
        const scale: f32 = 1.0 / 255.0;
        const clear = vk.ClearColorValue{ .float32 = .{
            @as(f32, @floatFromInt(bytes[0])) * scale,
            @as(f32, @floatFromInt(bytes[1])) * scale,
            @as(f32, @floatFromInt(bytes[2])) * scale,
            @as(f32, @floatFromInt(bytes[3])) * scale,
        } };
        const range = vk.ImageSubresourceRange{ .aspect_mask = vk.image_aspect_color_bit };
        self.device_functions.cmd_clear_color_image(
            command_buffer,
            snapshot.image.handle,
            vk.image_layout_transfer_dst_optimal,
            &clear,
            1,
            @ptrCast(&range),
        );
        const to_attachment = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_color_attachment_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_color_attachment_output_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_attachment),
        );
        try self.submitOneShot(command_buffer);

        self.render_target_sequence +%= 1;
        const cached = &self.render_targets.items[target_index];
        cached.initialized = true;
        cached.shader_read_layout = false;
        cached.gpu_generation +%= 1;
        cached.last_used_sequence = self.render_target_sequence;
        self.latest_render_target_index = target_index;
        for (self.completed_frames.items) |*frame| {
            if (frame.guest_address == descriptor.address) frame.needs_writeback = false;
        }
        self.emulated_buffer_clear_dispatches += 1;
        if (log_verbose_gpu or self.emulated_buffer_clear_dispatches <= 4) {
            std.debug.print(
                "[vulkan dcb] emulated packed color clear: addr=0x{x} bytes=0x{x} records={d} (#{d})\n",
                .{ descriptor.address, packed_value, descriptor.record_count, self.emulated_buffer_clear_dispatches },
            );
        }
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    /// Executes the compact AGC UAV-clear kernel shapes seen during bootstrap.
    ///
    /// Both kernels form x/y from an 8x8 workgroup, take z from the workgroup
    /// id, load constant texels from the first constant buffer, and issue one or
    /// two image_store operations. Matching the complete instruction shape keeps this
    /// path honest: general MIMG control flow and typed conversion still go
    /// through the translator and remain explicit when unsupported.
    fn tryEmulateImageStoreClear(
        self: *Renderer,
        memory: GuestMemory,
        bindings: *const gpu.ShaderBindings,
        reader: gpu.ShaderMemoryReader,
        analysis: *const gpu.ShaderAnalysis,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        const instructions = analysis.program.instructions.items;
        if (matchesDualImageClear(instructions)) {
            return self.emulateDualImageClear(
                memory,
                bindings,
                reader,
                instructions,
                system,
                local_size,
                group_count,
            );
        }
        const Shape = enum { rgba, scalar };
        const shape: Shape = if (matchesRgbaImageClear(instructions))
            .rgba
        else if (matchesScalarImageClear(instructions))
            .scalar
        else
            return null;
        if (local_size[0] != 8 or local_size[1] != 8 or local_size[2] != 1) return null;

        const image_inst = switch (shape) {
            .rgba => instructions[9],
            .scalar => instructions[6],
        };
        const descriptor = try resolveReadWriteImageDescriptor(bindings, reader, image_inst.src1.reg) orelse
            return null;
        if (descriptor.dcc_enabled or descriptor.cmask_fast_clear or descriptor.fmask_compression or
            descriptor.metadata_address != 0 or descriptor.samplesLog2() != 0 or
            descriptor.viewMipLevels() != 1 or descriptor.viewBaseLevel() != 0 or
            image_inst.image_dimension != .dim_2d_array_alt)
        {
            return null;
        }
        if (shape == .scalar and descriptor.dst_select[0] != 4) return null;

        const constants = (try bindings.inlineBufferDescriptor(8)) orelse blk: {
            const binding = (try bindings.resolve(reader, .constant_buffer, 0)) orelse return null;
            break :blk binding.descriptor.constant_buffer;
        };
        const word_count: usize = if (shape == .rgba) 4 else 1;
        if (constants.address == 0 or constants.size_bytes < word_count * @sizeOf(u32)) return null;
        var values: [4]u32 = @splat(0);
        for (values[0..word_count], 0..) |*value, index| {
            value.* = try readGuestU32(memory, constants.address + index * @sizeOf(u32));
        }
        const texel = packImageStoreTexel(
            descriptor.unified_format,
            values,
            image_inst.data_mask,
            descriptor.dst_select,
        ) orelse return null;

        const texture = gpu.TextureLayout.fromImage(descriptor) catch return null;
        const subresource = texture.subresource(0, 0, texture.layers) catch return null;
        if (texel.length != subresource.block.bytes_per_element) return null;

        const dispatched_width = std.math.mul(u64, group_count[0], local_size[0]) catch
            return Error.GuestBufferTooLarge;
        const dispatched_height = std.math.mul(u64, group_count[1], local_size[1]) catch
            return Error.GuestBufferTooLarge;
        const width: u32 = @intCast(@min(@as(u64, subresource.width), dispatched_width));
        const height: u32 = @intCast(@min(@as(u64, subresource.height), dispatched_height));
        const depth = @min(subresource.depth_or_layers, group_count[2]);

        var writes: u64 = 0;
        for (0..depth) |z_index| {
            const z: u32 = @intCast(z_index);
            for (0..height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    const offset = try subresource.sourceByteOffset(x, y, z, 0);
                    const address = std.math.add(u64, descriptor.address, offset) catch
                        return Error.GuestMemoryWriteFailed;
                    if (!memory.write(memory.context, address, texel.bytes[0..texel.length])) {
                        return Error.GuestMemoryWriteFailed;
                    }
                    writes += 1;
                }
            }
        }

        self.emulated_image_store_dispatches += 1;
        if (log_verbose_gpu or self.emulated_image_store_dispatches <= 4) {
            std.debug.print(
                "[vulkan dcb] emulated image clear: {d} texels addr=0x{x} fmt={d} tile={s} (#{d})\n",
                .{
                    writes,
                    descriptor.address,
                    descriptor.unified_format,
                    @tagName(descriptor.tile_mode),
                    self.emulated_image_store_dispatches,
                },
            );
        }
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    fn emulateDualImageClear(
        self: *Renderer,
        memory: GuestMemory,
        bindings: *const gpu.ShaderBindings,
        reader: gpu.ShaderMemoryReader,
        instructions: []const gpu.ShaderInstruction,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        if (local_size[0] != 4 or local_size[1] != 4 or local_size[2] != 1 or
            system.workgroup_id_sgprs[0] != 14 or
            system.workgroup_id_sgprs[1] != 15 or
            system.local_invocation_id_components != 2)
        {
            self.reportDualImageClearFallback("compute system registers", null, null);
            return null;
        }

        const first = try resolveReadWriteImageDescriptor(bindings, reader, 0) orelse {
            self.reportDualImageClearFallback("first image descriptor", null, null);
            return null;
        };
        const second = try imageDescriptorFromUserDataPointer(bindings, reader, 12) orelse {
            self.reportDualImageClearFallback("second image descriptor pointer", first, null);
            return null;
        };
        const constants = (try bindings.inlineBufferDescriptor(8)) orelse {
            self.reportDualImageClearFallback("constant buffer descriptor", first, second);
            return null;
        };
        const constant_offset: u64 = 384;
        if (constants.address == 0 or constants.size_bytes < constant_offset + 3 * @sizeOf(u32)) {
            self.reportDualImageClearFallback("constant buffer range", first, second);
            return null;
        }

        var first_values: [4]u32 = .{ 0, 0, 0, @bitCast(@as(f32, -1.0)) };
        for (first_values[0..3], 0..) |*value, index| {
            value.* = try readGuestU32(memory, constants.address + constant_offset + index * @sizeOf(u32));
        }
        const second_values = [4]u32{ 0, 0, 0, @bitCast(@as(f32, -1.0)) };

        const dispatched_width = std.math.mul(u64, group_count[0], local_size[0]) catch
            return Error.GuestBufferTooLarge;
        const dispatched_height = std.math.mul(u64, group_count[1], local_size[1]) catch
            return Error.GuestBufferTooLarge;
        const first_clear = planWholeImageClear(
            first,
            first_values,
            instructions[14].data_mask,
            dispatched_width,
            dispatched_height,
        ) orelse {
            self.reportDualImageClearFallback("first image layout/format", first, second);
            return null;
        };
        const second_clear = planWholeImageClear(
            second,
            second_values,
            instructions[16].data_mask,
            dispatched_width,
            dispatched_height,
        ) orelse {
            self.reportDualImageClearFallback("second image layout/format", first, second);
            return null;
        };
        const first_writes = try self.applyWholeImageClear(memory, first_clear);
        const second_writes = try self.applyWholeImageClear(memory, second_clear);

        self.emulated_image_store_dispatches += 1;
        std.debug.print(
            "[vulkan dcb] emulated dual image clear: {d}+{d} texels fmt={d}/{d} tile={s}/{s} (#{d})\n",
            .{
                first_writes,
                second_writes,
                first.unified_format,
                second.unified_format,
                @tagName(first.tile_mode),
                @tagName(second.tile_mode),
                self.emulated_image_store_dispatches,
            },
        );
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    fn reportDualImageClearFallback(
        self: *Renderer,
        reason: []const u8,
        first: ?gpu.ImageDescriptor,
        second: ?gpu.ImageDescriptor,
    ) void {
        if (self.reported_dual_image_clear_fallback) return;
        self.reported_dual_image_clear_fallback = true;
        std.debug.print("[vulkan dcb] dual image clear fallback: {s}\n", .{reason});
        for ([_]?gpu.ImageDescriptor{ first, second }, 0..) |maybe, index| {
            const image = maybe orelse continue;
            std.debug.print(
                "  image[{d}] addr=0x{x} {d}x{d}x{d} pitch={d} fmt={d} type={s} tile={s} levels={d}/{d} samples={d} meta=0x{x} dcc={any} cmask={any} fmask={any}\n",
                .{
                    index,
                    image.address,
                    image.width,
                    image.height,
                    image.depth_or_layers,
                    image.pitch,
                    image.unified_format,
                    @tagName(image.image_type),
                    @tagName(image.tile_mode),
                    image.viewBaseLevel(),
                    image.viewMipLevels(),
                    image.samplesLog2(),
                    image.metadata_address,
                    image.dcc_enabled,
                    image.cmask_fast_clear,
                    image.fmask_compression,
                },
            );
        }
    }

    fn applyWholeImageClear(
        self: *Renderer,
        memory: GuestMemory,
        clear: WholeImageClear,
    ) anyerror!u64 {
        const allocation = try self.allocator.alloc(u8, clear.allocation_bytes);
        defer self.allocator.free(allocation);
        if (!memory.read(memory.context, clear.descriptor.address, allocation)) return Error.GuestMemoryReadFailed;
        for (0..clear.subresource.height) |y_index| {
            const y: u32 = @intCast(y_index);
            for (0..clear.subresource.width) |x_index| {
                const x: u32 = @intCast(x_index);
                const offset_u64 = try clear.subresource.sourceByteOffset(x, y, 0, 0);
                const offset = std.math.cast(usize, offset_u64) orelse return Error.GuestBufferTooLarge;
                if (offset > allocation.len or clear.texel.length > allocation.len - offset) {
                    return Error.GuestBufferTooLarge;
                }
                @memcpy(
                    allocation[offset..][0..clear.texel.length],
                    clear.texel.bytes[0..clear.texel.length],
                );
            }
        }
        if (!memory.write(memory.context, clear.descriptor.address, allocation)) return Error.GuestMemoryWriteFailed;
        return @as(u64, clear.subresource.width) * clear.subresource.height;
    }

    /// Executes the bounded AGC buffer-to-3D-image upload kernel used for
    /// small lookup textures. The exact shader shape is matched separately;
    /// this method only implements its observed R8->RGBA8 and R16->R16 typed
    /// transfers and leaves general image-store programs to the translator.
    fn tryEmulateVolumeBufferCopy(
        self: *Renderer,
        memory: GuestMemory,
        bindings: *const gpu.ShaderBindings,
        reader: gpu.ShaderMemoryReader,
        analysis: *const gpu.ShaderAnalysis,
        system: gpu.resources.ComputeSystemRegisters,
        local_size: [3]u32,
        group_count: [3]u32,
    ) anyerror!?DispatchReport {
        if (!matchesVolumeBufferCopy(analysis.program.instructions.items)) return null;
        if (local_size[0] != 8 or local_size[1] != 8 or local_size[2] != 1 or
            system.workgroup_id_sgprs[0] != 16 or
            system.workgroup_id_sgprs[1] != 17 or
            system.workgroup_id_sgprs[2] != 18 or
            system.local_invocation_id_components != 2)
        {
            return null;
        }

        const source = (try bindings.inlineBufferDescriptor(8)) orelse return null;
        const control = (try bindings.inlineBufferDescriptor(12)) orelse return null;
        const image = try resolveReadWriteImageDescriptor(bindings, reader, 0) orelse return null;
        if (source.address == 0 or source.record_count == 0 or source.swizzle_enabled or
            source.add_thread_id or source.index_stride != 0 or source.out_of_bounds_select != 0 or
            source.dst_select[0] != 4 or control.address == 0 or control.size_bytes < 44 or
            image.image_type != .color_3d or image.dcc_enabled or image.cmask_fast_clear or
            image.fmask_compression or image.metadata_address != 0 or image.samplesLog2() != 0 or
            image.viewMipLevels() != 1 or image.viewBaseLevel() != 0)
        {
            return null;
        }
        const format_supported = (source.unified_format == 5 and source.stride == 1 and
            image.unified_format == 60) or
            (source.unified_format == 11 and source.stride == 2 and image.unified_format == 11);
        if (!format_supported) return null;

        var words: [11]u32 = undefined;
        for (&words, 0..) |*word, index| {
            word.* = try readGuestU32(memory, control.address + index * @sizeOf(u32));
        }
        const texture = gpu.TextureLayout.fromImage(image) catch return null;
        const subresource = texture.subresource(0, 0, 1) catch return null;

        const dispatched_x = std.math.mul(u64, group_count[0], local_size[0]) catch
            return Error.GuestBufferTooLarge;
        const dispatched_y = std.math.mul(u64, group_count[1], local_size[1]) catch
            return Error.GuestBufferTooLarge;
        const dispatched_z = std.math.mul(u64, group_count[2], local_size[2]) catch
            return Error.GuestBufferTooLarge;
        const base_x = words[4];
        const base_y = words[5];
        const base_z = words[6];
        if (base_x > subresource.width or base_y > subresource.height or
            base_z > subresource.depth_or_layers) return null;
        const width: u32 = @intCast(@min(
            @as(u64, @min(words[8], subresource.width - base_x)),
            dispatched_x,
        ));
        const height: u32 = @intCast(@min(
            @as(u64, @min(words[9], subresource.height - base_y)),
            dispatched_y,
        ));
        const depth: u32 = @intCast(@min(
            @as(u64, @min(words[10], subresource.depth_or_layers - base_z)),
            dispatched_z,
        ));
        const texel_count = std.math.mul(u64, width, height) catch return Error.GuestBufferTooLarge;
        const volume_texels = std.math.mul(u64, texel_count, depth) catch return Error.GuestBufferTooLarge;
        if (volume_texels > 16 * 1024 * 1024) return null;

        var writes: u64 = 0;
        for (0..depth) |z_index| {
            const z: u32 = @intCast(z_index);
            for (0..height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    const source_index = volumeSourceIndex(words[0..3].*, x, y, z) catch
                        return Error.GuestBufferTooLarge;
                    var values: [4]u32 = @splat(0);
                    for (&values, 0..) |*value, channel| {
                        const index = std.math.add(u64, source_index, channel) catch
                            return Error.GuestBufferTooLarge;
                        value.* = try readTypedBufferValue(memory, source, index);
                    }
                    const texel = packImageStoreTexel(
                        image.unified_format,
                        values,
                        0xf,
                        image.dst_select,
                    ) orelse return null;
                    if (texel.length != subresource.block.bytes_per_element) return null;

                    const target_x = base_x + x;
                    const target_y = base_y + y;
                    const target_z = base_z + z;
                    const offset = try subresource.sourceByteOffset(target_x, target_y, target_z, 0);
                    const address = std.math.add(u64, image.address, offset) catch
                        return Error.GuestMemoryWriteFailed;
                    if (!memory.write(memory.context, address, texel.bytes[0..texel.length])) {
                        return Error.GuestMemoryWriteFailed;
                    }
                    writes += 1;
                }
            }
        }

        self.emulated_volume_copies += 1;
        if (log_verbose_gpu or self.emulated_volume_copies <= 4) {
            std.debug.print(
                "[vulkan dcb] emulated volume upload: {d} texels src_fmt={d} dst_fmt={d} tile={s} (#{d})\n",
                .{
                    writes,
                    source.unified_format,
                    image.unified_format,
                    @tagName(image.tile_mode),
                    self.emulated_volume_copies,
                },
            );
        }
        return .{ .pipeline_cache_hit = false, .group_count = group_count, .spirv_words = 0 };
    }

    fn prepareComputeResources(
        self: *Renderer,
        bindings: *const gpu.ShaderBindings,
        reader: gpu.ShaderMemoryReader,
        analysis: *const gpu.ShaderAnalysis,
        scalar: *const gpu.ScalarEvaluation,
        specialized_scalar_prefix_end: u32,
        reserved_resources: ?*const ComputeResources,
    ) anyerror!ComputeResources {
        var result = ComputeResources{};
        errdefer result.deinit(self);
        result.specialized_scalar_prefix_end = specialized_scalar_prefix_end;
        if (reserved_resources) |reserved| {
            for (reserved.occupied, 0..) |used, index| {
                if (!used) continue;
                result.occupied[index] = true;
                result.addresses[index] = reserved.addresses[index];
                result.sizes[index] = reserved.sizes[index];
            }
        }
        const is_vertex_stage = switch (bindings.stage) {
            .vertex, .geometry, .export_shader, .hull => true,
            .pixel, .compute => false,
        };
        const vertex_table = if (is_vertex_stage)
            (gpu.VertexBindings.capture(bindings, reader) catch null)
        else
            null;
        var vertex_attribute_index: usize = 0;
        result.scalar_count = collectScalarLoadSpecializations(scalar, &result.scalar_registers);
        result.scalar_count = mergeUserDataScalars(
            bindings,
            bindings.scalar_user_data_base,
            &result.scalar_registers,
            result.scalar_count,
        );
        // Preserve the AGC slot number whenever possible. This makes the host
        // descriptor table stable across shaders that share one SRT layout.
        var iterator = bindings.iterator(reader, .constant_buffer);
        while (try iterator.next()) |binding| {
            const descriptor = binding.descriptor.constant_buffer;
            if (descriptor.isNull() or descriptor.size_bytes == 0) continue;
            const size = std.math.cast(usize, descriptor.size_bytes) orelse return Error.GuestBufferTooLarge;
            if (result.descriptorForRange(descriptor.address, size) != null) continue;
            const descriptor_index: u32 = if (binding.mapping.slot < maximum_storage_descriptors and
                !result.occupied[binding.mapping.slot])
                binding.mapping.slot
            else
                result.freeDescriptor() orelse return Error.InvalidStorageDescriptor;
            _ = try self.stageGuestStorageBufferAt(descriptor_index, descriptor.address, size);
            result.occupied[descriptor_index] = true;
            result.addresses[descriptor_index] = descriptor.address;
            result.sizes[descriptor_index] = size;
        }

        for (analysis.program.instructions.items) |inst| {
            const is_store = switch (inst.opcode) {
                .buffer_load_ubyte,
                .buffer_load_sbyte,
                .buffer_load_ushort,
                .buffer_load_sshort,
                .buffer_load_dword,
                .buffer_load_dwordx2,
                .buffer_load_dwordx3,
                .buffer_load_dwordx4,
                .buffer_load_format_x,
                .buffer_load_format_xy,
                .buffer_load_format_xyz,
                .buffer_load_format_xyzw,
                .s_buffer_load_dword,
                .s_buffer_load_dwordx2,
                .s_buffer_load_dwordx4,
                .s_buffer_load_dwordx8,
                .s_buffer_load_dwordx16,
                => false,
                .buffer_store_byte,
                .buffer_store_short,
                .buffer_store_dword,
                .buffer_store_dwordx2,
                .buffer_store_dwordx3,
                .buffer_store_dwordx4,
                .buffer_store_format_x,
                .buffer_store_format_xy,
                .buffer_store_format_xyz,
                .buffer_store_format_xyzw,
                .buffer_atomic_swap,
                .buffer_atomic_add,
                .buffer_atomic_sub,
                .buffer_atomic_smin,
                .buffer_atomic_umin,
                .buffer_atomic_smax,
                .buffer_atomic_umax,
                .buffer_atomic_and,
                .buffer_atomic_or,
                .buffer_atomic_xor,
                => true,
                else => continue,
            };
            const resource_operand = if (inst.family == .smem) inst.src0 else inst.src1;
            if (resource_operand.kind != .sgpr) {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] MissingStorageDescriptor: pc=0x{x} {s} resource is {s} not sgpr\n",
                    .{ inst.pc, @tagName(inst.opcode), @tagName(resource_operand.kind) },
                );
                return Error.MissingStorageDescriptor;
            }
            const resource_sgpr = resource_operand.reg;
            var vertex_attribute: ?gpu.VertexAttribute = null;
            if (bindings.stage != .compute and inst.family != .smem and !is_store) {
                if (vertex_table) |table| {
                    if (vertex_attribute_index < table.attribute_count) {
                        vertex_attribute = table.attributes[vertex_attribute_index];
                        vertex_attribute_index += 1;
                    }
                }
            }
            // Resolve the descriptor at the instruction itself. Shader prologs
            // reuse the same SGPR quartet for several SMEM-loaded V# values;
            // a final whole-program snapshot (or the first mapping for that
            // SGPR) is not authoritative for a later MUBUF operation.
            const instruction_scalar = gpu.scalar_provenance.evaluateResourceStateUntil(
                reader,
                bindings,
                inst.pc,
            );
            // The instruction-local scalar state is authoritative. Attribute
            // tables are ordered by semantic/location, while shader fetches
            // are free to consume those attributes in a different order. In
            // particular, JnG2 loads UV before color although its AGC table
            // lists color before UV; pairing both lists by index swaps their
            // V# descriptors and leaves every texture lookup at one corner.
            // Keep the table entry only as a fallback for shaders whose V#
            // producer cannot yet be reconstructed.
            const descriptor = try resolveComputeBufferDescriptor(
                bindings,
                reader,
                analysis,
                &instruction_scalar,
                &instruction_scalar,
                resource_sgpr,
                inst.pc,
            ) orelse (if (vertex_attribute) |attribute|
                takePlausibleBufferDescriptor(attribute.buffer)
            else
                null) orelse {
                if (log_verbose_gpu) {
                    const full = gpu.scalar_provenance.evaluatePrefix(reader, bindings);
                    std.debug.print(
                        "[vulkan dcb] MissingStorageDescriptor: pc=0x{x} {s} V# s{d}:s{d} unknown (scalar stop={s} @0x{x}, loads={d}, user_data={d}); soft-skip\n",
                        .{
                            inst.pc,
                            @tagName(inst.opcode),
                            resource_sgpr,
                            resource_sgpr + 3,
                            @tagName(full.stop_reason),
                            full.stop_pc,
                            full.load_count,
                            bindings.user_data_count,
                        },
                    );
                }
                // Soft-skip: keep mapping other resources so a single missing
                // V# does not abort the whole draw/dispatch.
                continue;
            };
            if (descriptor.isNull() or descriptor.size_bytes == 0) {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] MissingStorageDescriptor: pc=0x{x} {s} V# s{d} null/empty (addr=0x{x} size={d}); soft-skip\n",
                    .{
                        inst.pc,
                        @tagName(inst.opcode),
                        resource_sgpr,
                        descriptor.address,
                        descriptor.size_bytes,
                    },
                );
                continue;
            }
            const size = std.math.cast(usize, descriptor.size_bytes) orelse {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] GuestBufferTooLarge: V# s{d} size_bytes=0x{x}; soft-skip\n",
                    .{ resource_sgpr, descriptor.size_bytes },
                );
                continue;
            };
            const descriptor_index = result.descriptorForRange(descriptor.address, size) orelse blk: {
                const free = result.freeDescriptor() orelse {
                    if (log_verbose_gpu) std.debug.print("[vulkan dcb] no free storage slot for V# s{d}; soft-skip\n", .{resource_sgpr});
                    continue;
                };
                _ = self.stageGuestStorageBufferAt(free, descriptor.address, size) catch |err| {
                    if (log_verbose_gpu) std.debug.print(
                        "[vulkan dcb] stage V# s{d} failed: {s} addr=0x{x} size=0x{x} stride={d} records={d}; soft-skip\n",
                        .{
                            resource_sgpr,
                            @errorName(err),
                            descriptor.address,
                            size,
                            descriptor.stride,
                            descriptor.record_count,
                        },
                    );
                    continue;
                };
                result.occupied[free] = true;
                result.addresses[free] = descriptor.address;
                result.sizes[free] = size;
                break :blk free;
            };
            const previous_descriptor_index = result.mappingForSgpr(resource_sgpr);
            // Constant-buffer mappings are interchangeable when the SGPR and
            // staged range match. Vertex attributes are not: several fetches
            // commonly share one V# and buffer while using different table
            // offsets, so every instruction needs its own PC-qualified entry.
            if (canReuseStorageMapping(
                vertex_attribute != null,
                previous_descriptor_index,
                descriptor_index,
            )) {
                if (is_store) result.writable[descriptor_index] = true;
                continue;
            }
            if (result.mapping_count >= result.mappings.len) {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] no free V# mapping for pc=0x{x} s{d}; soft-skip\n",
                    .{ inst.pc, resource_sgpr },
                );
                continue;
            }
            result.mappings[result.mapping_count] = .{
                .resource_sgpr = resource_sgpr,
                .descriptor_index = descriptor_index,
                .instruction_pc = if (vertex_attribute != null or
                    previous_descriptor_index != null)
                    inst.pc
                else
                    null,
                .soffset_value = if (vertex_attribute) |attribute| attribute.offset_bytes else null,
                .use_vertex_index = vertex_attribute != null,
                .stride = descriptor.stride,
                .swizzled = descriptor.swizzle_enabled,
                .index_stride = descriptor.index_stride,
                .add_thread_id = descriptor.add_thread_id,
                .unified_format = descriptor.unified_format,
                .dst_select = descriptor.dst_select,
                // The descriptor already says how far the buffer goes, so the
                // shader can be held to it instead of being trusted to stay
                // inside on its own.
                .extent_bytes = std.math.cast(u32, descriptor.size_bytes),
            };
            result.mapping_count += 1;
            if (is_store) result.writable[descriptor_index] = true;
        }

        for (analysis.program.instructions.items) |inst| {
            const writable = switch (inst.opcode) {
                .image_load => false,
                .image_store => true,
                else => continue,
            };
            if (inst.src1.kind != .sgpr) {
                std.debug.print(
                    "[vulkan dcb] storage image pc=0x{x}: resource is {s}, not SGPR\n",
                    .{ inst.pc, @tagName(inst.src1.kind) },
                );
                return Error.UnsupportedStorageImage;
            }
            const resource_sgpr = inst.src1.reg;
            if (result.storageImageMappingForSgpr(resource_sgpr)) |descriptor_index| {
                if (writable) result.storage_images[descriptor_index].writable = true;
                continue;
            }
            if (result.storage_image_mapping_count >= maximum_storage_images) {
                return Error.UnsupportedStorageImage;
            }
            const descriptor = (try resolveComputeImageDescriptor(
                bindings,
                reader,
                analysis,
                scalar,
                resource_sgpr,
                result.storage_image_mapping_count,
            )) orelse {
                std.debug.print(
                    "[vulkan dcb] storage image pc=0x{x}: T# s{d}:s{d} unresolved\n",
                    .{ inst.pc, resource_sgpr, resource_sgpr + 7 },
                );
                return Error.UnsupportedStorageImage;
            };
            const format = storageImageFormat(descriptor.unified_format) orelse {
                std.debug.print(
                    "[vulkan dcb] storage image pc=0x{x}: format {d} is unsupported\n",
                    .{ inst.pc, descriptor.unified_format },
                );
                return Error.UnsupportedStorageImage;
            };
            var descriptor_index: ?u32 = null;
            for (result.storage_images[0..result.storage_image_count], 0..) |*existing, index| {
                if (existing.descriptor.address == descriptor.address and
                    existing.descriptor.width == descriptor.width and
                    existing.descriptor.height == descriptor.height and
                    existing.descriptor.depth_or_layers == descriptor.depth_or_layers and
                    existing.descriptor.unified_format == descriptor.unified_format and
                    existing.descriptor.tile_mode == descriptor.tile_mode and
                    existing.descriptor.image_type == descriptor.image_type)
                {
                    if (writable) existing.writable = true;
                    descriptor_index = @intCast(index);
                    break;
                }
            }
            if (descriptor_index == null) {
                if (result.storage_image_count >= maximum_storage_images) {
                    return Error.UnsupportedStorageImage;
                }
                const index: u32 = @intCast(result.storage_image_count);
                result.storage_images[result.storage_image_count] = self.stageStorageImage(
                    descriptor,
                    index,
                    writable,
                ) catch |err| {
                    std.debug.print(
                        "[vulkan dcb] storage image pc=0x{x}: stage failed {s} addr=0x{x} {d}x{d}x{d} pitch={d} fmt={d} type={s} tile={s} levels={d}..{d} base_array={d} flags=0x{x} metadata=0x{x} dcc={any} cmask={any} fmask={any}\n",
                        .{
                            inst.pc,
                            @errorName(err),
                            descriptor.address,
                            descriptor.width,
                            descriptor.height,
                            descriptor.depth_or_layers,
                            descriptor.pitch,
                            descriptor.unified_format,
                            @tagName(descriptor.image_type),
                            @tagName(descriptor.tile_mode),
                            descriptor.base_level,
                            descriptor.last_level,
                            descriptor.base_array,
                            descriptor.descriptor_flags,
                            descriptor.metadata_address,
                            descriptor.dcc_enabled,
                            descriptor.cmask_fast_clear,
                            descriptor.fmask_compression,
                        },
                    );
                    return err;
                };
                result.storage_image_count += 1;
                descriptor_index = index;
            }
            result.storage_image_mappings[result.storage_image_mapping_count] = .{
                .resource_sgpr = resource_sgpr,
                .descriptor_index = descriptor_index.?,
                .format = format.spirv,
                .dimension = if (descriptor.image_type == .color_3d) .three_d else .two_d,
                .dst_select = descriptor.dst_select,
            };
            result.storage_image_mapping_count += 1;
        }

        for (analysis.program.instructions.items) |inst| {
            if (inst.opcode != .image_sample) continue;
            if (inst.src1.kind != .sgpr or inst.src2.kind != .sgpr) {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] sampled image pc=0x{x}: T# is {s}, S# is {s}\n",
                    .{ inst.pc, @tagName(inst.src1.kind), @tagName(inst.src2.kind) },
                );
                return Error.UnsupportedSampledImage;
            }
            const resource_sgpr = inst.src1.reg;
            const sampler_sgpr = inst.src2.reg;
            if (result.sampledImageMappingForInstruction(resource_sgpr, sampler_sgpr, inst.pc) != null) continue;
            if (result.sampled_image_mapping_count >= maximum_sampled_images) {
                return Error.UnsupportedSampledImage;
            }

            const descriptor_slot = result.sampled_image_mapping_count;
            const sampled_scalar = gpu.scalar_provenance.evaluateResourceStateUntil(
                reader,
                bindings,
                inst.pc,
            );
            const image_descriptor = (try resolveComputeSampledImageDescriptor(
                bindings,
                reader,
                analysis,
                &sampled_scalar,
                resource_sgpr,
                inst.pc,
                descriptor_slot,
            )) orelse {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] sampled image pc=0x{x}: T# s{d}:s{d} unresolved\n",
                    .{ inst.pc, resource_sgpr, resource_sgpr + 7 },
                );
                return Error.UnsupportedSampledImage;
            };
            const sampler_descriptor = (try resolveComputeSamplerDescriptor(
                bindings,
                reader,
                analysis,
                &sampled_scalar,
                sampler_sgpr,
                inst.pc,
                descriptor_slot,
            )) orelse {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] sampled image pc=0x{x}: S# s{d}:s{d} unresolved\n",
                    .{ inst.pc, sampler_sgpr, sampler_sgpr + 3 },
                );
                return Error.UnsupportedSampledImage;
            };
            const descriptor_index: u32 = @intCast(descriptor_slot);
            const image = self.stageSampledImage(
                image_descriptor,
                sampler_descriptor,
                descriptor_index,
            ) catch |err| {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] sampled image pc=0x{x}: stage failed {s} addr=0x{x} {d}x{d} fmt={d} type={s}\n",
                    .{
                        inst.pc,
                        @errorName(err),
                        image_descriptor.address,
                        image_descriptor.width,
                        image_descriptor.height,
                        image_descriptor.unified_format,
                        @tagName(image_descriptor.image_type),
                    },
                );
                return err;
            };
            result.sampled_images[result.sampled_image_count] = image;
            result.sampled_image_count += 1;
            result.sampled_image_mappings[result.sampled_image_mapping_count] = .{
                .resource_sgpr = resource_sgpr,
                .sampler_sgpr = sampler_sgpr,
                .descriptor_index = descriptor_index,
                .dimension = if (image_descriptor.image_type == .color_3d) .three_d else .two_d,
                .instruction_pc = inst.pc,
            };
            result.sampled_image_mapping_count += 1;
        }
        return result;
    }

    fn commitComputeWrites(self: *Renderer, memory: GuestMemory, resources: *const ComputeResources) anyerror!void {
        const profile_started = hostTimestampNs();
        defer self.frame_profile.storage_commit_ns +|= elapsedHostNanoseconds(profile_started);
        for (resources.writable, 0..) |writable, index| {
            if (!writable) continue;
            if (resources.sizes[index] >= deferred_storage_write_min_bytes) {
                for (self.guest_buffers.items) |*entry| {
                    if (entry.guest_address != resources.addresses[index] or
                        entry.size != resources.sizes[index]) continue;
                    entry.gpu_dirty = true;
                    break;
                }
                continue;
            }
            const bytes = try self.allocator.alloc(u8, resources.sizes[index]);
            defer self.allocator.free(bytes);
            try self.readbackGuestStorageBuffer(resources.addresses[index], bytes);
            if (!memory.write(memory.context, resources.addresses[index], bytes)) return Error.GuestMemoryWriteFailed;
        }
    }

    fn getComputePipeline(self: *Renderer, words: []const u32) (Error || std.mem.Allocator.Error)!PipelineLookup {
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words));
        for (self.compute_pipelines.items) |entry| {
            if (entry.hash == hash and std.mem.eql(u32, entry.words, words)) {
                self.pipeline_cache_hits += 1;
                return .{ .pipeline = entry.pipeline, .cache_hit = true };
            }
        }
        if (self.compute_pipelines.items.len >= maximum_compute_pipelines) return Error.ComputePipelineCacheFull;

        const owned_words = try self.allocator.dupe(u32, words);
        errdefer self.allocator.free(owned_words);
        const shader = try self.createShader(words);
        errdefer self.device_functions.destroy_shader_module(self.device, shader, null);
        const stage = vk.PipelineShaderStageCreateInfo{
            .stage = vk.shader_stage_compute_bit,
            .module = shader,
            .name = "main",
        };
        const pipeline_info = vk.ComputePipelineCreateInfo{
            .stage = stage,
            .layout = self.compute_pipeline_layout,
        };
        var pipeline: vk.Pipeline = 0;
        if (self.device_functions.create_compute_pipelines(
            self.device,
            self.driver_pipeline_cache,
            1,
            @ptrCast(&pipeline_info),
            null,
            @ptrCast(&pipeline),
        ) != vk.success) return Error.ComputePipelineCreationFailed;
        errdefer self.device_functions.destroy_pipeline(self.device, pipeline, null);
        try self.compute_pipelines.append(self.allocator, .{
            .hash = hash,
            .words = owned_words,
            .shader = shader,
            .pipeline = pipeline,
        });
        self.pipeline_cache_misses += 1;
        return .{ .pipeline = pipeline, .cache_hit = false };
    }

    pub fn smokeTest(self: *Renderer) Error!SmokeReport {
        const word_count = 16;
        const byte_count = word_count * @sizeOf(u32);
        var expected: [word_count]u32 = undefined;
        for (&expected, 0..) |*word, index| word.* = 0x51a9_c000 | @as(u32, @intCast(index));

        const source = try self.createBuffer(
            byte_count,
            vk.buffer_usage_transfer_src_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(source);
        const target = try self.createBuffer(
            byte_count,
            vk.buffer_usage_transfer_src_bit | vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_storage_buffer_bit,
            0x0000_0001,
        );
        defer self.destroyBuffer(target);
        const readback = try self.createBuffer(
            byte_count,
            vk.buffer_usage_transfer_dst_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(readback);

        try self.writeMapped(source, std.mem.sliceAsBytes(&expected));

        const shader = try self.createSmokeShader();
        defer self.device_functions.destroy_shader_module(self.device, shader, null);

        const stage = vk.PipelineShaderStageCreateInfo{
            .stage = vk.shader_stage_compute_bit,
            .module = shader,
            .name = "main",
        };
        const pipeline_info = vk.ComputePipelineCreateInfo{ .stage = stage, .layout = self.compute_pipeline_layout };
        var pipeline: vk.Pipeline = 0;
        if (self.device_functions.create_compute_pipelines(self.device, self.driver_pipeline_cache, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline)) != vk.success) {
            return Error.ComputePipelineCreationFailed;
        }
        defer self.device_functions.destroy_pipeline(self.device, pipeline, null);

        const allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = vk.command_buffer_level_primary,
            .command_buffer_count = 1,
        };
        var command_buffer: vk.CommandBuffer = undefined;
        if (self.device_functions.allocate_command_buffers(self.device, &allocate_info, @ptrCast(&command_buffer)) != vk.success) {
            return Error.CommandBufferAllocationFailed;
        }
        defer self.releaseOneShot(command_buffer);

        const begin_info = vk.CommandBufferBeginInfo{ .flags = vk.command_buffer_usage_one_time_submit_bit };
        if (self.device_functions.begin_command_buffer(command_buffer, &begin_info) != vk.success) {
            return Error.CommandBufferBeginFailed;
        }
        self.device_functions.cmd_bind_pipeline(command_buffer, vk.pipeline_bind_point_compute, pipeline);
        self.device_functions.cmd_dispatch(command_buffer, 1, 1, 1);

        const source_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_host_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .buffer = source.handle,
            .offset = 0,
            .size = source.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_host_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&source_barrier),
            0,
            null,
        );
        const copy = vk.BufferCopy{ .source_offset = 0, .destination_offset = 0, .size = byte_count };
        self.device_functions.cmd_copy_buffer(command_buffer, source.handle, target.handle, 1, @ptrCast(&copy));

        const target_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .buffer = target.handle,
            .offset = 0,
            .size = target.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&target_barrier),
            0,
            null,
        );
        self.device_functions.cmd_copy_buffer(command_buffer, target.handle, readback.handle, 1, @ptrCast(&copy));

        const readback_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_host_read_bit,
            .buffer = readback.handle,
            .offset = 0,
            .size = readback.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_host_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&readback_barrier),
            0,
            null,
        );
        if (self.device_functions.end_command_buffer(command_buffer) != vk.success) return Error.CommandBufferEndFailed;

        const fence_info = vk.FenceCreateInfo{};
        var fence: vk.Fence = 0;
        if (self.device_functions.create_fence(self.device, &fence_info, null, &fence) != vk.success) {
            return Error.FenceCreationFailed;
        }
        defer self.device_functions.destroy_fence(self.device, fence, null);
        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .command_buffers = @ptrCast(&command_buffer),
        };
        if (self.device_functions.queue_submit(self.queue, 1, @ptrCast(&submit_info), fence) != vk.success) {
            return Error.QueueSubmissionFailed;
        }
        if (self.device_functions.wait_for_fences(self.device, 1, @ptrCast(&fence), vk.true_value, ~@as(u64, 0)) != vk.success) {
            return Error.FenceWaitFailed;
        }
        try self.expectMapped(readback, std.mem.sliceAsBytes(&expected));

        return .{
            .bytes_copied = byte_count,
            .compute_dispatches = 1,
            .queue_family_index = self.queue_family_index,
        };
    }

    fn createGraphicsRenderPass(self: *Renderer, format: u32, preserve_color: bool) Error!vk.RenderPass {
        const attachment = vk.AttachmentDescription{
            .format = format,
            .load_operation = if (preserve_color) vk.attachment_load_op_load else vk.attachment_load_op_clear,
            .store_operation = vk.attachment_store_op_store,
            .initial_layout = if (preserve_color) vk.image_layout_color_attachment_optimal else vk.image_layout_undefined,
            .final_layout = vk.image_layout_color_attachment_optimal,
        };
        const reference = vk.AttachmentReference{
            .attachment = 0,
            .layout = vk.image_layout_color_attachment_optimal,
        };
        const subpass = vk.SubpassDescription{
            .color_attachment_count = 1,
            .color_attachments = @ptrCast(&reference),
        };
        const info = vk.RenderPassCreateInfo{
            .attachment_count = 1,
            .attachments = @ptrCast(&attachment),
            .subpass_count = 1,
            .subpasses = @ptrCast(&subpass),
        };
        var render_pass: vk.RenderPass = 0;
        if (self.device_functions.create_render_pass(self.device, &info, null, &render_pass) != vk.success) {
            return Error.RenderPassCreationFailed;
        }
        return render_pass;
    }

    /// Brings a depth attachment into the layout its render pass expects, and
    /// applies the guest's depth clear when one is pending.
    ///
    /// A freshly created image has undefined contents, so the first use always
    /// clears: a title that enables the depth test before its own clear would
    /// otherwise compare against whatever the allocator left behind. Later
    /// clears happen only when DB_RENDER_CONTROL asks for one.
    fn prepareDepthAttachment(
        self: *Renderer,
        command_buffer: vk.CommandBuffer,
        depth_index: usize,
        clear_requested: bool,
    ) void {
        const cached = &self.depth_targets.items[depth_index];
        const first_use = !cached.initialized;
        const clearing = clear_requested or first_use;
        const range = vk.ImageSubresourceRange{ .aspect_mask = vk.image_aspect_depth_bit };

        const old_layout: u32 = if (first_use)
            vk.image_layout_undefined
        else
            vk.image_layout_depth_stencil_attachment_optimal;
        const target_layout: u32 = if (clearing)
            vk.image_layout_transfer_dst_optimal
        else
            vk.image_layout_depth_stencil_attachment_optimal;

        const to_target = vk.ImageMemoryBarrier{
            .source_access_mask = if (first_use) 0 else vk.access_depth_stencil_attachment_write_bit,
            .destination_access_mask = if (clearing)
                vk.access_transfer_write_bit
            else
                vk.access_depth_stencil_attachment_read_bit | vk.access_depth_stencil_attachment_write_bit,
            .old_layout = old_layout,
            .new_layout = target_layout,
            .image = cached.image.handle,
            .subresource_range = range,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            if (first_use) vk.pipeline_stage_top_of_pipe_bit else vk.pipeline_stage_late_fragment_tests_bit,
            if (clearing) vk.pipeline_stage_transfer_bit else vk.pipeline_stage_early_fragment_tests_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_target),
        );
        cached.initialized = true;
        if (!clearing) return;

        const clear = vk.ClearDepthStencilValue{
            .depth = std.math.clamp(cached.target.clear_depth, 0, 1),
            .stencil = 0,
        };
        self.device_functions.cmd_clear_depth_stencil_image(
            command_buffer,
            cached.image.handle,
            vk.image_layout_transfer_dst_optimal,
            &clear,
            1,
            @ptrCast(&range),
        );
        const to_attachment = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_depth_stencil_attachment_read_bit |
                vk.access_depth_stencil_attachment_write_bit,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_depth_stencil_attachment_optimal,
            .image = cached.image.handle,
            .subresource_range = range,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_early_fragment_tests_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_attachment),
        );
    }

    /// A render pass that keeps both attachments across draws.
    ///
    /// Depth loads rather than clears for the same reason colour does: a title
    /// builds a frame from many draws against one allocation, and a clear baked
    /// into the pass would erase what the previous draw established. The guest's
    /// own depth clear is issued separately, against the image.
    fn createDepthGraphicsRenderPass(
        self: *Renderer,
        color_format: u32,
        depth_format: u32,
        preserve_color: bool,
    ) Error!vk.RenderPass {
        const attachments = [2]vk.AttachmentDescription{
            .{
                .format = color_format,
                .load_operation = if (preserve_color) vk.attachment_load_op_load else vk.attachment_load_op_clear,
                .store_operation = vk.attachment_store_op_store,
                .initial_layout = if (preserve_color) vk.image_layout_color_attachment_optimal else vk.image_layout_undefined,
                .final_layout = vk.image_layout_color_attachment_optimal,
            },
            .{
                .format = depth_format,
                .load_operation = vk.attachment_load_op_load,
                .store_operation = vk.attachment_store_op_store,
                .initial_layout = vk.image_layout_depth_stencil_attachment_optimal,
                .final_layout = vk.image_layout_depth_stencil_attachment_optimal,
            },
        };
        const color_reference = vk.AttachmentReference{
            .attachment = 0,
            .layout = vk.image_layout_color_attachment_optimal,
        };
        const depth_reference = vk.AttachmentReference{
            .attachment = 1,
            .layout = vk.image_layout_depth_stencil_attachment_optimal,
        };
        const subpass = vk.SubpassDescription{
            .color_attachment_count = 1,
            .color_attachments = @ptrCast(&color_reference),
            .depth_stencil_attachment = &depth_reference,
        };
        const info = vk.RenderPassCreateInfo{
            .attachment_count = attachments.len,
            .attachments = &attachments,
            .subpass_count = 1,
            .subpasses = @ptrCast(&subpass),
        };
        var render_pass: vk.RenderPass = 0;
        if (self.device_functions.create_render_pass(self.device, &info, null, &render_pass) != vk.success) {
            return Error.RenderPassCreationFailed;
        }
        return render_pass;
    }

    /// The colour target's framebuffer paired with one depth attachment,
    /// rebuilt only when the pairing changes.
    fn acquireDepthPass(
        self: *Renderer,
        target_index: usize,
        depth_index: usize,
    ) anyerror!DepthPass {
        const color = self.render_targets.items[target_index];
        const depth = self.depth_targets.items[depth_index];
        if (color.depth_pass) |existing| {
            if (existing.depth_view == depth.view and existing.depth_format == depth.target.format) {
                return existing;
            }
            self.destroyDepthPass(existing);
            self.render_targets.items[target_index].depth_pass = null;
        }

        const color_format = colorTargetFormat(color.target.descriptor) orelse
            return Error.UnsupportedColorTarget;
        const render_pass = try self.createDepthGraphicsRenderPass(
            color_format.vulkan,
            depth.target.format,
            true,
        );
        errdefer self.device_functions.destroy_render_pass(self.device, render_pass, null);

        const views = [2]vk.ImageView{ color.view, depth.view };
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = views.len,
            .attachments = &views,
            .width = color.target.descriptor.width,
            .height = color.target.descriptor.height,
        };
        var framebuffer: vk.Framebuffer = 0;
        if (self.device_functions.create_framebuffer(self.device, &framebuffer_info, null, &framebuffer) != vk.success) {
            return Error.FramebufferCreationFailed;
        }
        const pass = DepthPass{
            .depth_view = depth.view,
            .depth_format = depth.target.format,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
        };
        self.render_targets.items[target_index].depth_pass = pass;
        return pass;
    }

    fn guestGraphicsState(render: *const gpu.RenderState, target: gpu.resources.ColorTarget) Error!GraphicsPipelineState {
        var result = GraphicsPipelineState.default(target.width, target.height);
        if (render.viewport) |viewport| {
            const x = viewport.x_offset - viewport.x_scale;
            const y = viewport.y_offset - viewport.y_scale;
            const width = viewport.x_scale * 2.0;
            const height = viewport.y_scale * 2.0;
            const min_depth = viewport.z_offset;
            const max_depth = viewport.z_offset + viewport.z_scale;
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or
                !std.math.isFinite(width) or !std.math.isFinite(height) or
                !std.math.isFinite(min_depth) or !std.math.isFinite(max_depth) or
                width == 0 or height == 0)
            {
                return Error.UnsupportedGraphicsState;
            }
            result.viewport_x_bits = @bitCast(x);
            result.viewport_y_bits = @bitCast(y);
            result.viewport_width_bits = @bitCast(width);
            result.viewport_height_bits = @bitCast(height);
            result.viewport_min_depth_bits = @bitCast(std.math.clamp(min_depth, 0, 1));
            result.viewport_max_depth_bits = @bitCast(std.math.clamp(max_depth, 0, 1));
        }
        if (render.scissor) |scissor| {
            const left: u32 = @min(scissor.left, target.width);
            const top: u32 = @min(scissor.top, target.height);
            const right: u32 = @min(@max(scissor.right, left), target.width);
            const bottom: u32 = @min(@max(scissor.bottom, top), target.height);
            result.scissor_x = @intCast(left);
            result.scissor_y = @intCast(top);
            result.scissor_width = right - left;
            result.scissor_height = bottom - top;
        }
        if (render.raster.polygon_mode != 0 or
            render.raster.depth_bias_front or render.raster.depth_bias_back)
        {
            return Error.UnsupportedGraphicsState;
        }
        // Ignore guest culling on the first host path: attribute fetch and
        // winding often disagree until NGG export is fully correct, and a
        // full cull makes every black writeback look identical.
        result.cull_mode = 0;
        result.front_face = if (render.raster.clockwise_front_face) 0 else 1;
        result.rasterizer_discard = @intFromBool(render.raster.rasterizer_discard);
        result.color_write_mask = target.write_mask;

        const blend = render.blends[target.slot];
        result.blend_enable = @intFromBool(blend.enabled);
        if (blend.enabled) {
            result.source_color_blend_factor = try vulkanBlendFactor(blend.color_source);
            result.destination_color_blend_factor = try vulkanBlendFactor(blend.color_destination);
            result.color_blend_operation = try vulkanBlendOperation(blend.color_operation);
            result.source_alpha_blend_factor = if (blend.separate_alpha)
                try vulkanBlendFactor(blend.alpha_source)
            else
                result.source_color_blend_factor;
            result.destination_alpha_blend_factor = if (blend.separate_alpha)
                try vulkanBlendFactor(blend.alpha_destination)
            else
                result.destination_color_blend_factor;
            result.alpha_blend_operation = if (blend.separate_alpha)
                try vulkanBlendOperation(blend.alpha_operation)
            else
                result.color_blend_operation;
        }
        return result;
    }

    fn vulkanBlendFactor(factor: u5) Error!u32 {
        return switch (factor) {
            0...3 => factor,
            4 => 6,
            5 => 7,
            6 => 8,
            7 => 9,
            8 => 4,
            9 => 5,
            10 => 14,
            13 => 10,
            14 => 11,
            15 => 15,
            16 => 16,
            17 => 17,
            18 => 18,
            19 => 12,
            20 => 13,
            else => Error.UnsupportedGraphicsState,
        };
    }

    fn vulkanBlendOperation(operation: u3) Error!u32 {
        return switch (operation) {
            0, 1 => operation,
            2 => 3,
            3 => 4,
            4 => 2,
            else => Error.UnsupportedGraphicsState,
        };
    }

    fn createGraphicsPipeline(
        self: *Renderer,
        render_pass: vk.RenderPass,
        pipeline_state: GraphicsPipelineState,
        vertex_words: []const u32,
        fragment_words: []const u32,
    ) Error!vk.Pipeline {
        const vertex = try self.createShader(vertex_words);
        defer self.device_functions.destroy_shader_module(self.device, vertex, null);
        const fragment = try self.createShader(fragment_words);
        defer self.device_functions.destroy_shader_module(self.device, fragment, null);
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = vk.shader_stage_vertex_bit, .module = vertex, .name = "main" },
            .{ .stage = vk.shader_stage_fragment_bit, .module = fragment, .name = "main" },
        };
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{};
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = pipeline_state.topology,
        };
        const viewport = vk.Viewport{
            .x = @bitCast(pipeline_state.viewport_x_bits),
            .y = @bitCast(pipeline_state.viewport_y_bits),
            .width = @bitCast(pipeline_state.viewport_width_bits),
            .height = @bitCast(pipeline_state.viewport_height_bits),
            .min_depth = @bitCast(pipeline_state.viewport_min_depth_bits),
            .max_depth = @bitCast(pipeline_state.viewport_max_depth_bits),
        };
        const scissor = vk.Rect2D{
            .offset = .{ .x = pipeline_state.scissor_x, .y = pipeline_state.scissor_y },
            .extent = .{ .width = pipeline_state.scissor_width, .height = pipeline_state.scissor_height },
        };
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .viewports = @ptrCast(&viewport),
            .scissor_count = 1,
            .scissors = @ptrCast(&scissor),
        };
        const rasterization = vk.PipelineRasterizationStateCreateInfo{
            .rasterizer_discard_enable = pipeline_state.rasterizer_discard,
            .cull_mode = pipeline_state.cull_mode,
            .front_face = pipeline_state.front_face,
        };
        const multisample = vk.PipelineMultisampleStateCreateInfo{};
        const blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = pipeline_state.blend_enable,
            .source_color_blend_factor = pipeline_state.source_color_blend_factor,
            .destination_color_blend_factor = pipeline_state.destination_color_blend_factor,
            .color_blend_operation = pipeline_state.color_blend_operation,
            .source_alpha_blend_factor = pipeline_state.source_alpha_blend_factor,
            .destination_alpha_blend_factor = pipeline_state.destination_alpha_blend_factor,
            .alpha_blend_operation = pipeline_state.alpha_blend_operation,
            .color_write_mask = pipeline_state.color_write_mask,
        };
        const color_blend = vk.PipelineColorBlendStateCreateInfo{
            .attachment_count = 1,
            .attachments = @ptrCast(&blend_attachment),
        };
        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = pipeline_state.depth_test_enable,
            .depth_write_enable = pipeline_state.depth_write_enable,
            .depth_compare_operation = pipeline_state.depth_compare_operation,
        };
        const info = vk.GraphicsPipelineCreateInfo{
            .stage_count = stages.len,
            .stages = &stages,
            .vertex_input_state = &vertex_input,
            .input_assembly_state = &input_assembly,
            .viewport_state = &viewport_state,
            .rasterization_state = &rasterization,
            .multisample_state = &multisample,
            .depth_stencil_state = if (pipeline_state.depth_attachment_format != 0) &depth_stencil else null,
            .color_blend_state = &color_blend,
            .layout = self.compute_pipeline_layout,
            .render_pass = render_pass,
        };
        var pipeline: vk.Pipeline = 0;
        if (self.device_functions.create_graphics_pipelines(
            self.device,
            self.driver_pipeline_cache,
            1,
            @ptrCast(&info),
            null,
            @ptrCast(&pipeline),
        ) != vk.success) {
            return Error.GraphicsPipelineCreationFailed;
        }
        return pipeline;
    }

    /// The decoded form of one guest shader program, reused across draws.
    ///
    /// Decoding walks the instruction stream a word at a time out of guest
    /// memory and then lowers it to IR. That result depends on the program's
    /// own bytes and nothing else, so repeating it for every draw of the same
    /// shader is pure cost. A candidate is confirmed by comparing the words it
    /// was decoded from against guest memory, which is a bulk read and a
    /// compare rather than a decode; a program rebuilt at the same address is
    /// therefore picked up instead of being served stale.
    ///
    /// The returned pointer stays valid for the caller's draw: capacity is
    /// reserved up front so entries never move, and the entry just returned
    /// carries the newest sequence, so a later miss in the same draw cannot
    /// choose it as the least-recently-used victim.
    fn analyzedProgram(
        self: *Renderer,
        reader: gpu.ShaderMemoryReader,
        address: u64,
    ) anyerror!*const gpu.ShaderAnalysis {
        self.analyzed_program_sequence +%= 1;
        var stale_index: ?usize = null;
        for (self.analyzed_programs.items, 0..) |*entry, index| {
            if (entry.address != address) continue;
            if (programWordsMatch(reader, address, entry.analysis.code.items)) {
                entry.last_used_sequence = self.analyzed_program_sequence;
                self.frame_profile.shader_analysis_hits += 1;
                return &entry.analysis;
            }
            stale_index = index;
            break;
        }

        const started = hostTimestampNs();
        var analysis = try gpu.shader_analysis.decode(
            self.allocator,
            reader,
            address,
            maximum_shader_instructions,
        );
        errdefer analysis.deinit(self.allocator);
        self.frame_profile.shader_analysis_ns +|= elapsedHostNanoseconds(started);
        self.frame_profile.shader_analysis_misses += 1;
        const replacement = AnalyzedProgram{
            .address = address,
            .analysis = analysis,
            .last_used_sequence = self.analyzed_program_sequence,
        };

        const slot = stale_index orelse blk: {
            if (self.analyzed_programs.items.len < maximum_analyzed_programs) {
                try self.analyzed_programs.ensureTotalCapacity(self.allocator, maximum_analyzed_programs);
                self.analyzed_programs.appendAssumeCapacity(replacement);
                return &self.analyzed_programs.items[self.analyzed_programs.items.len - 1].analysis;
            }
            var oldest_index: usize = 0;
            var oldest_sequence = self.analyzed_programs.items[0].last_used_sequence;
            for (self.analyzed_programs.items[1..], 1..) |entry, index| {
                if (entry.last_used_sequence >= oldest_sequence) continue;
                oldest_index = index;
                oldest_sequence = entry.last_used_sequence;
            }
            break :blk oldest_index;
        };
        const victim = &self.analyzed_programs.items[slot];
        victim.analysis.deinit(self.allocator);
        victim.* = replacement;
        return &victim.analysis;
    }

    /// The content probe of one sampled source, taken at most once per frame
    /// per source. See `TextureProbe`.
    fn probeSampledSource(
        self: *Renderer,
        memory: GuestMemory,
        address: u64,
        span: usize,
        source_generation: u64,
    ) u64 {
        for (self.texture_probes[0..self.texture_probe_count]) |probe| {
            if (!probe.valid or probe.address != address or probe.span != span) continue;
            if (probe.source_generation != source_generation) break;
            return probe.hash;
        }
        const started = hostTimestampNs();
        const hash = hashGuestMemoryRange(memory, address, span);
        self.frame_profile.texture_probe_ns +|= elapsedHostNanoseconds(started);

        const entry = TextureProbe{
            .address = address,
            .span = span,
            .source_generation = source_generation,
            .hash = hash,
            .valid = true,
        };
        for (self.texture_probes[0..self.texture_probe_count]) |*probe| {
            if (probe.address != address or probe.span != span) continue;
            probe.* = entry;
            return hash;
        }
        if (self.texture_probe_count < self.texture_probes.len) {
            self.texture_probes[self.texture_probe_count] = entry;
            self.texture_probe_count += 1;
        }
        return hash;
    }

    fn getGraphicsPipeline(
        self: *Renderer,
        render_pass: vk.RenderPass,
        pipeline_state: GraphicsPipelineState,
        vertex_words: []const u32,
        fragment_words: []const u32,
    ) (Error || std.mem.Allocator.Error)!vk.Pipeline {
        self.graphics_pipeline_sequence +%= 1;
        const state_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&pipeline_state));
        const vertex_hash_only = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vertex_words));
        const fragment_hash_only = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(fragment_words));
        const vertex_hash = std.hash.Wyhash.hash(state_hash, std.mem.sliceAsBytes(vertex_words));
        const hash = std.hash.Wyhash.hash(vertex_hash, std.mem.sliceAsBytes(fragment_words));
        var state_match = false;
        var vertex_match = false;
        var fragment_match = false;
        for (self.graphics_pipelines.items) |*entry| {
            state_match = state_match or entry.state_hash == state_hash;
            vertex_match = vertex_match or entry.vertex_hash == vertex_hash_only;
            fragment_match = fragment_match or entry.fragment_hash == fragment_hash_only;
            if (entry.hash == hash and
                std.mem.eql(u8, std.mem.asBytes(&entry.state), std.mem.asBytes(&pipeline_state)) and
                std.mem.eql(u32, entry.vertex_words, vertex_words) and
                std.mem.eql(u32, entry.fragment_words, fragment_words))
            {
                self.graphics_pipeline_cache_hits += 1;
                self.frame_profile.graphics_pipeline_hits += 1;
                entry.last_used_sequence = self.graphics_pipeline_sequence;
                return entry.pipeline;
            }
        }
        const owned_vertex = try self.allocator.dupe(u32, vertex_words);
        errdefer self.allocator.free(owned_vertex);
        const owned_fragment = try self.allocator.dupe(u32, fragment_words);
        errdefer self.allocator.free(owned_fragment);
        const build_started = hostTimestampNs();
        const pipeline = try self.createGraphicsPipeline(render_pass, pipeline_state, vertex_words, fragment_words);
        self.frame_profile.graphics_pipeline_build_ns +|= elapsedHostNanoseconds(build_started);
        errdefer self.device_functions.destroy_pipeline(self.device, pipeline, null);
        const replacement = GraphicsPipelineEntry{
            .hash = hash,
            .state_hash = state_hash,
            .vertex_hash = vertex_hash_only,
            .fragment_hash = fragment_hash_only,
            .state = pipeline_state,
            .vertex_words = owned_vertex,
            .fragment_words = owned_fragment,
            .pipeline = pipeline,
            .last_used_sequence = self.graphics_pipeline_sequence,
        };
        if (self.graphics_pipelines.items.len < maximum_graphics_pipelines) {
            try self.graphics_pipelines.append(self.allocator, replacement);
        } else {
            // Every one-shot submission is fenced before returning, so the
            // least-recently-used pipeline cannot still be executing here.
            // Recycling it preserves correctness in titles which specialize
            // transform constants into more than 256 shader variants.
            var oldest_index: usize = 0;
            var oldest_sequence = self.graphics_pipelines.items[0].last_used_sequence;
            for (self.graphics_pipelines.items[1..], 1..) |entry, index| {
                if (entry.last_used_sequence >= oldest_sequence) continue;
                oldest_index = index;
                oldest_sequence = entry.last_used_sequence;
            }
            const victim = &self.graphics_pipelines.items[oldest_index];
            self.device_functions.destroy_pipeline(self.device, victim.pipeline, null);
            self.allocator.free(victim.vertex_words);
            self.allocator.free(victim.fragment_words);
            victim.* = replacement;
        }
        self.graphics_pipeline_cache_misses += 1;
        self.frame_profile.graphics_pipeline_misses += 1;
        self.frame_profile.graphics_pipeline_miss_state_match += @intFromBool(state_match);
        self.frame_profile.graphics_pipeline_miss_vertex_match += @intFromBool(vertex_match);
        self.frame_profile.graphics_pipeline_miss_fragment_match += @intFromBool(fragment_match);
        return pipeline;
    }

    fn colorTargetFrameBytes(target: GuestColorTarget) Error!usize {
        const bytes = std.math.cast(usize, target.layout.staging_bytes) orelse
            return Error.UnsupportedColorTarget;
        if (bytes == 0 or bytes > maximum_frame_bytes) return Error.UnsupportedColorTarget;
        return bytes;
    }

    fn sameRenderTarget(a: GuestColorTarget, b: GuestColorTarget) bool {
        return a.descriptor.address == b.descriptor.address and
            a.descriptor.width == b.descriptor.width and
            a.descriptor.height == b.descriptor.height and
            a.descriptor.pitch == b.descriptor.pitch and
            a.descriptor.format == b.descriptor.format and
            a.descriptor.number_type == b.descriptor.number_type and
            a.descriptor.component_swap == b.descriptor.component_swap and
            a.descriptor.force_destination_alpha_one == b.descriptor.force_destination_alpha_one and
            a.descriptor.tile_mode == b.descriptor.tile_mode and
            a.descriptor.samples_log2 == b.descriptor.samples_log2 and
            a.descriptor.fragments_log2 == b.descriptor.fragments_log2 and
            a.descriptor.base_array_slice == b.descriptor.base_array_slice and
            a.descriptor.mip_level == b.descriptor.mip_level and
            a.format.vulkan == b.format.vulkan and
            a.format.bytes_per_texel == b.format.bytes_per_texel and
            a.layout.required_source_bytes == b.layout.required_source_bytes and
            a.layout.staging_bytes == b.layout.staging_bytes;
    }

    fn sameRenderTargetMetadata(a: gpu.resources.ColorTarget, b: gpu.resources.ColorTarget) bool {
        return a.dcc_enabled == b.dcc_enabled and
            a.cmask_fast_clear == b.cmask_fast_clear and
            a.cmask_linear == b.cmask_linear and
            a.fmask_compression == b.fmask_compression and
            a.cmask_address == b.cmask_address and
            a.cmask_slice_bytes == b.cmask_slice_bytes and
            a.fmask_address == b.fmask_address and
            a.dcc_address == b.dcc_address;
    }

    /// Resolves what a DCC-compressed colour target actually reads as.
    ///
    /// A target with DCC enabled does not hold plain texels: the key holds one
    /// byte per 256-byte block saying whether that block was fast cleared, and
    /// the base allocation only holds compressed data for blocks something has
    /// since rendered into. Staging the base allocation as an image is
    /// therefore only meaningful when the key reads uncompressed everywhere;
    /// a uniform clear code means the hardware returns the clear colour for
    /// every texel, whatever the bytes underneath happen to be.
    ///
    /// Returns null when the raw allocation is the honest source: no DCC, a
    /// key we cannot read, a mixed key, or a code this does not model.
    fn colorTargetFastClearTexel(self: *Renderer, target: GuestColorTarget) anyerror!?DccClearTexel {
        const descriptor = target.descriptor;
        if (!descriptor.dcc_enabled or descriptor.dcc_address == 0) return null;
        const memory = self.guest_memory orelse return null;
        const key_bytes_u64 = target.layout.required_source_bytes / dcc_block_bytes;
        if (key_bytes_u64 == 0 or key_bytes_u64 > maximum_dcc_key_bytes) return null;
        const key_bytes: usize = @intCast(key_bytes_u64);
        const key = try self.allocator.alloc(u8, key_bytes);
        defer self.allocator.free(key);
        if (!memory.read(memory.context, descriptor.dcc_address, key)) return null;
        const code = key[0];
        for (key[1..]) |byte| {
            if (byte != code) return null;
        }
        return colorDccClearTexel(code, descriptor);
    }

    fn stageCmaskFastClear(
        self: *Renderer,
        target: GuestColorTarget,
        reader: gpu.ShaderMemoryReader,
        frame: []u8,
    ) anyerror!?CmaskSeed {
        const descriptor = target.descriptor;
        if (!descriptor.cmask_fast_clear or descriptor.cmask_address == 0 or descriptor.dcc_enabled) return null;
        const texel = clearWordTexel(descriptor) orelse return null;
        const layout = gpu.CmaskLayout.fromColorTarget(descriptor) catch return null;
        const byte_count = std.math.cast(usize, layout.required_bytes) orelse return null;
        if (byte_count == 0 or byte_count > maximum_cmask_bytes) return null;
        const metadata = try self.allocator.alloc(u8, byte_count);
        defer self.allocator.free(metadata);
        const memory = self.guest_memory orelse return null;
        if (!memory.read(memory.context, descriptor.cmask_address, metadata)) return null;

        const stats = classifyCmaskBlocks(layout, metadata) orelse {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] CMASK contains an unsupported compressed state @0x{x}\n",
                .{descriptor.cmask_address},
            );
            return null;
        };
        if (stats.expanded_blocks == 0) {
            fillRgba8(frame, texel);
        } else {
            try target.layout.stage(reader, descriptor.address, frame);
            applyCmaskClearBlocks(layout, metadata, frame, texel);
        }
        return .{
            .texel = texel,
            .clear_blocks = stats.clear_blocks,
            .expanded_blocks = stats.expanded_blocks,
        };
    }

    fn stageInitialColorTarget(
        self: *Renderer,
        target: GuestColorTarget,
        reader: gpu.ShaderMemoryReader,
        frame: []u8,
    ) anyerror!void {
        if (try self.colorTargetFastClearTexel(target)) |texel| {
            fillTexels(frame, texel.bytes[0..texel.length]);
            self.reportDccFastClearSeed(target, texel);
            return;
        }
        if (try self.stageCmaskFastClear(target, reader, frame)) |seed| {
            if (seed.clear_blocks != 0) self.reportCmaskFastClearSeed(target, seed);
            return;
        }
        try target.layout.stage(reader, target.descriptor.address, frame);
    }

    fn reportDccFastClearSeed(self: *Renderer, target: GuestColorTarget, texel: DccClearTexel) void {
        if (self.reported_fast_clear_seeds >= 4 and !log_verbose_gpu) return;
        self.reported_fast_clear_seeds += 1;
        std.debug.print(
            "[vulkan dcb] dcc fast-clear target @0x{x} {d}x{d} key@0x{x} fmt={d} texel_bytes={d} raw={x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
            .{
                target.descriptor.address,
                target.descriptor.width,
                target.descriptor.height,
                target.descriptor.dcc_address,
                target.descriptor.format,
                texel.length,
                texel.bytes[0],
                texel.bytes[1],
                texel.bytes[2],
                texel.bytes[3],
                texel.bytes[4],
                texel.bytes[5],
                texel.bytes[6],
                texel.bytes[7],
            },
        );
    }

    fn reportCmaskFastClearSeed(self: *Renderer, target: GuestColorTarget, seed: CmaskSeed) void {
        if (self.reported_fast_clear_seeds >= 4 and !log_verbose_gpu) return;
        self.reported_fast_clear_seeds += 1;
        std.debug.print(
            "[vulkan dcb] cmask fast-clear target @0x{x} {d}x{d} meta@0x{x} blocks={d}/{d} rgba={d},{d},{d},{d}\n",
            .{
                target.descriptor.address,
                target.descriptor.width,
                target.descriptor.height,
                target.descriptor.cmask_address,
                seed.clear_blocks,
                seed.clear_blocks + seed.expanded_blocks,
                seed.texel[0],
                seed.texel[1],
                seed.texel[2],
                seed.texel[3],
            },
        );
    }

    fn sameHtileTarget(a: gpu.resources.DepthTarget, b: gpu.resources.DepthTarget) bool {
        return a.read_address == b.read_address and
            a.write_address == b.write_address and
            a.stencil_read_address == b.stencil_read_address and
            a.stencil_write_address == b.stencil_write_address and
            a.htile_address == b.htile_address and
            a.width == b.width and a.height == b.height and
            a.format == b.format and a.stencil_format == b.stencil_format and
            a.tile_mode == b.tile_mode and a.stencil_tile_mode == b.stencil_tile_mode and
            a.samples_log2 == b.samples_log2 and a.maximum_mip == b.maximum_mip and
            a.base_array_slice == b.base_array_slice and
            a.last_array_slice == b.last_array_slice and a.mip_level == b.mip_level and
            a.htile_enabled == b.htile_enabled and
            a.htile_pipe_aligned == b.htile_pipe_aligned and
            a.tile_stencil_disabled == b.tile_stencil_disabled;
    }

    fn acquireHtileTarget(self: *Renderer, target: gpu.resources.DepthTarget) !usize {
        self.htile_target_sequence +%= 1;
        for (self.htile_targets.items, 0..) |*cached, index| {
            if (!sameHtileTarget(cached.target, target)) continue;
            cached.target = target;
            cached.last_used_sequence = self.htile_target_sequence;
            return index;
        }
        const entry = CachedHtileTarget{
            .target = target,
            .last_used_sequence = self.htile_target_sequence,
        };
        if (self.htile_targets.items.len < maximum_depth_targets) {
            try self.htile_targets.append(self.allocator, entry);
            return self.htile_targets.items.len - 1;
        }
        var oldest_index: usize = 0;
        for (self.htile_targets.items[1..], 1..) |cached, index| {
            if (cached.last_used_sequence < self.htile_targets.items[oldest_index].last_used_sequence) {
                oldest_index = index;
            }
        }
        self.htile_targets.items[oldest_index] = entry;
        return oldest_index;
    }

    /// Materializes the only HTILE states which can make the base allocation
    /// stale: exact 0.0/1.0 fast clears. Ordinary Z-range words are left in
    /// place because their base depth/stencil texels are already authoritative.
    fn resolveHtileTarget(self: *Renderer, target: gpu.resources.DepthTarget) anyerror!void {
        if (!target.htile_enabled or target.htile_address == 0) return;
        const index = try self.acquireHtileTarget(target);
        if (self.htile_targets.items[index].resolved) return;
        const stats = try self.expandHtileFastClears(target);
        self.htile_targets.items[index].resolved = true;
        const resolved = stats orelse return;
        if (resolved.clearBlocks() == 0) return;
        if (self.reported_htile_resolves >= 4 and !log_verbose_gpu) return;
        self.reported_htile_resolves += 1;
        std.debug.print(
            "[vulkan dcb] htile fast-clear resolve depth@0x{x} {d}x{d} meta@0x{x} zero={d} one={d} base={d}\n",
            .{
                if (target.write_address != 0) target.write_address else target.read_address,
                target.width,
                target.height,
                target.htile_address,
                resolved.clear_zero_blocks,
                resolved.clear_one_blocks,
                resolved.base_blocks,
            },
        );
    }

    fn expandHtileFastClears(
        self: *Renderer,
        target: gpu.resources.DepthTarget,
    ) anyerror!?HtileResolveStats {
        const htile = gpu.HtileLayout.fromDepthTarget(target) catch return null;
        const metadata_bytes = std.math.cast(usize, htile.required_bytes) orelse return null;
        if (metadata_bytes == 0 or metadata_bytes > maximum_htile_bytes) return null;
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const metadata = try self.allocator.alloc(u8, metadata_bytes);
        defer self.allocator.free(metadata);
        if (!memory.read(memory.context, target.htile_address, metadata)) {
            return Error.GuestMemoryReadFailed;
        }

        const stats = classifyHtileBlocks(htile, metadata, target.tile_stencil_disabled) orelse return null;
        if (stats.clearBlocks() == 0) return stats;

        const depth_texture = gpu.TextureLayout.fromDepthTarget(target) catch return null;
        const depth = depth_texture.base() catch return null;
        const depth_bytes = std.math.cast(usize, depth_texture.required_source_bytes) orelse return null;
        if (depth_bytes == 0 or depth_bytes > maximum_frame_bytes) return null;
        var depth_addresses: [2]u64 = @splat(0);
        var depth_count: usize = 0;
        for ([_]u64{ target.read_address, target.write_address }) |address| {
            if (address == 0) continue;
            var duplicate = false;
            for (depth_addresses[0..depth_count]) |present| {
                if (present == address) duplicate = true;
            }
            if (!duplicate) {
                depth_addresses[depth_count] = address;
                depth_count += 1;
            }
        }
        if (depth_count == 0) return null;
        for (depth_addresses[0..depth_count]) |address| {
            const allocation = try self.allocator.alloc(u8, depth_bytes);
            defer self.allocator.free(allocation);
            if (!memory.read(memory.context, address, allocation)) return Error.GuestMemoryReadFailed;
            try applyHtileDepthFastClears(htile, metadata, target, depth, allocation);
            if (!memory.write(memory.context, address, allocation)) return Error.GuestMemoryWriteFailed;
        }

        if (!target.tile_stencil_disabled and target.stencil_format != 0) {
            const stencil_texture = gpu.TextureLayout.fromStencilTarget(target) catch return null;
            const stencil = stencil_texture.base() catch return null;
            const stencil_bytes = std.math.cast(usize, stencil_texture.required_source_bytes) orelse return null;
            if (stencil_bytes == 0 or stencil_bytes > maximum_frame_bytes) return null;
            var stencil_addresses: [2]u64 = @splat(0);
            var stencil_count: usize = 0;
            for ([_]u64{ target.stencil_read_address, target.stencil_write_address }) |address| {
                if (address == 0) continue;
                var duplicate = false;
                for (stencil_addresses[0..stencil_count]) |present| {
                    if (present == address) duplicate = true;
                }
                if (!duplicate) {
                    stencil_addresses[stencil_count] = address;
                    stencil_count += 1;
                }
            }
            // Expanding the shared depth/stencil word without publishing the
            // stencil clear would expose stale stencil bytes.
            if (stencil_count == 0) return null;
            for (stencil_addresses[0..stencil_count]) |address| {
                const allocation = try self.allocator.alloc(u8, stencil_bytes);
                defer self.allocator.free(allocation);
                if (!memory.read(memory.context, address, allocation)) return Error.GuestMemoryReadFailed;
                try applyHtileStencilFastClears(htile, metadata, target, stencil, allocation);
                if (!memory.write(memory.context, address, allocation)) return Error.GuestMemoryWriteFailed;
            }
        }

        for (0..htile.layers) |layer_index| {
            var y: u32 = 0;
            while (y < htile.height) : (y += gpu.HtileLayout.region_height) {
                var x: u32 = 0;
                while (x < htile.width) : (x += gpu.HtileLayout.region_width) {
                    const layer: u32 = @intCast(layer_index);
                    const word = try htile.word(metadata, x, y, layer);
                    if (gpu.HtileLayout.fastClearDepth(word, target.tile_stencil_disabled) == null) continue;
                    try htile.setWord(
                        metadata,
                        x,
                        y,
                        layer,
                        gpu.HtileLayout.expandedWord(target.tile_stencil_disabled),
                    );
                }
            }
        }
        if (!memory.write(memory.context, target.htile_address, metadata)) {
            return Error.GuestMemoryWriteFailed;
        }
        return stats;
    }

    fn materializeHtileTargetAt(self: *Renderer, address: u64, size: usize) anyerror!bool {
        for (self.htile_targets.items) |cached| {
            if (cached.resolved) continue;
            const target = cached.target;
            const depth = gpu.TextureLayout.fromDepthTarget(target) catch continue;
            const depth_hit = (target.read_address != 0 and byteRangesOverlap(
                address,
                size,
                target.read_address,
                depth.required_source_bytes,
            )) or (target.write_address != 0 and byteRangesOverlap(
                address,
                size,
                target.write_address,
                depth.required_source_bytes,
            ));
            var stencil_hit = false;
            if (!depth_hit and target.stencil_format != 0) {
                const stencil = gpu.TextureLayout.fromStencilTarget(target) catch continue;
                stencil_hit = (target.stencil_read_address != 0 and byteRangesOverlap(
                    address,
                    size,
                    target.stencil_read_address,
                    stencil.required_source_bytes,
                )) or (target.stencil_write_address != 0 and byteRangesOverlap(
                    address,
                    size,
                    target.stencil_write_address,
                    stencil.required_source_bytes,
                ));
            }
            if (!depth_hit and !stencil_hit) continue;
            try self.resolveHtileTarget(target);
            return true;
        }
        return false;
    }

    fn createCachedRenderTarget(self: *Renderer, target: GuestColorTarget) anyerror!CachedRenderTarget {
        const frame_bytes = try colorTargetFrameBytes(target);
        const image = try self.createImage(
            target.descriptor.width,
            target.descriptor.height,
            target.format.vulkan,
            vk.image_usage_color_attachment_bit |
                vk.image_usage_transfer_src_bit |
                vk.image_usage_transfer_dst_bit |
                vk.image_usage_sampled_bit,
        );
        errdefer self.destroyImage(image);

        const view_info = vk.ImageViewCreateInfo{
            .image = image.handle,
            .format = target.format.vulkan,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        var view: vk.ImageView = 0;
        if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
            return Error.ImageViewCreationFailed;
        }
        errdefer self.device_functions.destroy_image_view(self.device, view, null);

        const render_pass = try self.createGraphicsRenderPass(target.format.vulkan, true);
        errdefer self.device_functions.destroy_render_pass(self.device, render_pass, null);
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = 1,
            .attachments = @ptrCast(&view),
            .width = target.descriptor.width,
            .height = target.descriptor.height,
        };
        var framebuffer: vk.Framebuffer = 0;
        if (self.device_functions.create_framebuffer(self.device, &framebuffer_info, null, &framebuffer) != vk.success) {
            return Error.FramebufferCreationFailed;
        }
        errdefer self.device_functions.destroy_framebuffer(self.device, framebuffer, null);

        const readback = try self.createBuffer(
            frame_bytes,
            vk.buffer_usage_transfer_dst_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        errdefer self.destroyBuffer(readback);
        return .{
            .target = target,
            .image = image,
            .view = view,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .readback = readback,
        };
    }

    fn destroyCachedRenderTarget(self: *Renderer, target: CachedRenderTarget) void {
        self.destroyDepthPass(target.depth_pass);
        self.device_functions.destroy_framebuffer(self.device, target.framebuffer, null);
        self.device_functions.destroy_render_pass(self.device, target.render_pass, null);
        self.device_functions.destroy_image_view(self.device, target.view, null);
        self.destroyBuffer(target.readback);
        self.destroyImage(target.image);
    }

    fn destroyDepthPass(self: *Renderer, pass: ?DepthPass) void {
        const active = pass orelse return;
        self.device_functions.destroy_framebuffer(self.device, active.framebuffer, null);
        self.device_functions.destroy_render_pass(self.device, active.render_pass, null);
    }

    fn destroyCachedDepthTarget(self: *Renderer, target: CachedDepthTarget) void {
        self.device_functions.destroy_image_view(self.device, target.view, null);
        self.destroyImage(target.image);
    }

    fn transitionRenderTargetToShaderRead(self: *Renderer, index: usize) anyerror!void {
        if (index >= self.render_targets.items.len) return Error.MissingPresentedFrame;
        const snapshot = self.render_targets.items[index];
        if (!snapshot.initialized or snapshot.shader_read_layout) return;
        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const barrier = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_shader_read_bit,
            .old_layout = vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_shader_read_only_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_color_attachment_output_bit,
            vk.pipeline_stage_fragment_shader_bit | vk.pipeline_stage_compute_shader_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&barrier),
        );
        try self.submitOneShot(command_buffer);
        self.render_targets.items[index].shader_read_layout = true;
    }

    fn transitionRenderTargetToColorAttachment(self: *Renderer, index: usize) anyerror!void {
        if (index >= self.render_targets.items.len) return Error.MissingPresentedFrame;
        const snapshot = self.render_targets.items[index];
        if (!snapshot.initialized or !snapshot.shader_read_layout) return;
        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const barrier = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_shader_read_bit,
            .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .old_layout = vk.image_layout_shader_read_only_optimal,
            .new_layout = vk.image_layout_color_attachment_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_fragment_shader_bit | vk.pipeline_stage_compute_shader_bit,
            vk.pipeline_stage_color_attachment_output_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&barrier),
        );
        try self.submitOneShot(command_buffer);
        self.render_targets.items[index].shader_read_layout = false;
    }

    fn stageResidentRenderTarget(
        self: *Renderer,
        descriptor: gpu.resources.ImageDescriptor,
        sampler_descriptor: gpu.resources.SamplerDescriptor,
        image_format: u32,
        descriptor_index: u32,
    ) anyerror!?PreparedSampledImage {
        for (self.render_targets.items, 0..) |cached, index| {
            if (!cached.initialized or
                cached.target.descriptor.address != descriptor.address or
                cached.target.descriptor.width != descriptor.width or
                cached.target.descriptor.height != descriptor.height or
                cached.target.format.vulkan != image_format)
            {
                continue;
            }
            try self.transitionRenderTargetToShaderRead(index);
            const components = try sampledImageComponents(descriptor.dst_select);
            const view_info = vk.ImageViewCreateInfo{
                .image = cached.image.handle,
                .format = image_format,
                .components = components,
                .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
            };
            var view: vk.ImageView = 0;
            if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
                return Error.ImageViewCreationFailed;
            }
            errdefer self.device_functions.destroy_image_view(self.device, view, null);
            const sampler = try self.createGuestSampler(sampler_descriptor);
            errdefer self.device_functions.destroy_sampler(self.device, sampler, null);
            self.updateSampledImageDescriptor(descriptor_index, view, sampler, false);
            return .{
                .image = cached.image,
                .view = view,
                .sampler = sampler,
                .owns_view = true,
                .owns_sampler = true,
            };
        }
        return null;
    }

    /// Reduces the bound depth registers to the plane a Vulkan attachment can
    /// represent, or reports that this draw has no usable depth.
    fn guestDepthTarget(descriptor: gpu.resources.DepthTarget) ?GuestDepthTarget {
        const address = if (descriptor.write_address != 0)
            descriptor.write_address
        else
            descriptor.read_address;
        if (address == 0 or descriptor.width == 0 or descriptor.height == 0) return null;
        // Multi-sample depth would have to resolve against a multi-sample colour
        // attachment, and the colour path is still single-sample.
        if (descriptor.samples_log2 != 0) return null;
        const format = depthTargetFormat(descriptor) orelse return null;
        return .{
            .address = address,
            .width = descriptor.width,
            .height = descriptor.height,
            .guest_format = descriptor.format,
            .format = format,
            .tile_mode = descriptor.tile_mode,
            .base_array_slice = descriptor.base_array_slice,
            .mip_level = descriptor.mip_level,
            .clear_depth = descriptor.clear_depth,
        };
    }

    fn createCachedDepthTarget(self: *Renderer, target: GuestDepthTarget) anyerror!CachedDepthTarget {
        const image = try self.createImage(
            target.width,
            target.height,
            target.format,
            vk.image_usage_depth_stencil_attachment_bit | vk.image_usage_transfer_dst_bit,
        );
        errdefer self.destroyImage(image);

        const view_info = vk.ImageViewCreateInfo{
            .image = image.handle,
            .format = target.format,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_depth_bit },
        };
        var view: vk.ImageView = 0;
        if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
            return Error.ImageViewCreationFailed;
        }
        return .{ .target = target, .image = image, .view = view };
    }

    fn acquireDepthTarget(self: *Renderer, target: GuestDepthTarget) anyerror!usize {
        for (self.depth_targets.items, 0..) |cached_snapshot, index| {
            if (!cached_snapshot.target.sameAllocation(target)) continue;
            const cached = &self.depth_targets.items[index];
            // The clear value lives in its own register and moves without the
            // allocation changing; keep the newest one for the next clear.
            cached.target.clear_depth = target.clear_depth;
            self.depth_target_sequence +%= 1;
            cached.last_used_sequence = self.depth_target_sequence;
            return index;
        }

        var cached = try self.createCachedDepthTarget(target);
        self.depth_target_sequence +%= 1;
        cached.last_used_sequence = self.depth_target_sequence;
        if (self.depth_targets.items.len < maximum_depth_targets) {
            try self.depth_targets.append(self.allocator, cached);
            if (!self.reported_depth_attachment) {
                self.reported_depth_attachment = true;
                std.debug.print(
                    "[vulkan dcb] depth attachment: first @0x{x} {d}x{d} format={d}\n",
                    .{ target.address, target.width, target.height, target.guest_format },
                );
            }
            return self.depth_targets.items.len - 1;
        }

        // Every draw is fenced before it returns, so the least-recently-used
        // attachment cannot still be in flight when it is recycled.
        var oldest_index: usize = 0;
        var oldest_sequence = self.depth_targets.items[0].last_used_sequence;
        for (self.depth_targets.items[1..], 1..) |entry, index| {
            if (entry.last_used_sequence >= oldest_sequence) continue;
            oldest_index = index;
            oldest_sequence = entry.last_used_sequence;
        }
        const victim = &self.depth_targets.items[oldest_index];
        self.invalidateDepthPasses(victim.view);
        self.destroyCachedDepthTarget(victim.*);
        victim.* = cached;
        return oldest_index;
    }

    /// Drops any colour framebuffer still paired with a depth view that is
    /// about to be destroyed.
    fn invalidateDepthPasses(self: *Renderer, view: vk.ImageView) void {
        for (self.render_targets.items) |*cached| {
            const pass = cached.depth_pass orelse continue;
            if (pass.depth_view != view) continue;
            self.destroyDepthPass(pass);
            cached.depth_pass = null;
        }
    }

    fn acquireRenderTarget(self: *Renderer, target: GuestColorTarget) anyerror!usize {
        for (self.render_targets.items, 0..) |cached_snapshot, index| {
            if (!sameRenderTarget(cached_snapshot.target, target)) continue;
            const metadata_changed = !sameRenderTargetMetadata(cached_snapshot.target.descriptor, target.descriptor);
            if (metadata_changed and cached_snapshot.initialized) {
                const visible_bytes = try colorTargetFrameBytes(cached_snapshot.target);
                try self.flushPendingGuestWrite(cached_snapshot.target.descriptor.address, visible_bytes);
            }
            const cached = &self.render_targets.items[index];
            if (metadata_changed) cached.initialized = false;
            // Clear registers can change without changing the allocation.
            // Keep the newest descriptor for a subsequent metadata resolve.
            cached.target = target;
            self.render_target_sequence +%= 1;
            cached.last_used_sequence = self.render_target_sequence;
            self.frame_profile.render_target_hits += 1;
            return index;
        }
        if (self.render_targets.items.len >= maximum_render_targets) return Error.RenderTargetCacheFull;
        try self.render_targets.ensureUnusedCapacity(self.allocator, 1);
        var cached = try self.createCachedRenderTarget(target);
        self.render_target_sequence +%= 1;
        cached.last_used_sequence = self.render_target_sequence;
        self.render_targets.appendAssumeCapacity(cached);
        self.frame_profile.render_target_misses += 1;
        if (self.render_targets.items.len == 1) {
            std.debug.print(
                "[vulkan dcb] render target cache: first @0x{x} {d}x{d}\n",
                .{ target.descriptor.address, target.layout.width, target.layout.height },
            );
        }
        return self.render_targets.items.len - 1;
    }

    /// Copies one persistent attachment to host memory only when something
    /// outside the GPU needs it (flip, CPU visibility, or texture staging).
    /// Consecutive draws therefore stay resident and compose in-order.
    fn materializeRenderTarget(self: *Renderer, index: usize) anyerror!void {
        const profile_started = hostTimestampNs();
        defer self.frame_profile.target_materialize_ns +|= elapsedHostNanoseconds(profile_started);
        if (index >= self.render_targets.items.len) return Error.MissingPresentedFrame;
        const snapshot = self.render_targets.items[index];
        if (!snapshot.initialized) return;
        if (snapshot.gpu_generation == snapshot.host_generation) {
            try self.transitionRenderTargetToColorAttachment(index);
            return;
        }
        const frame_bytes = try colorTargetFrameBytes(snapshot.target);

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const to_transfer = vk.ImageMemoryBarrier{
            .source_access_mask = if (snapshot.shader_read_layout)
                vk.access_shader_read_bit
            else
                vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .old_layout = if (snapshot.shader_read_layout)
                vk.image_layout_shader_read_only_optimal
            else
                vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_transfer_src_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            if (snapshot.shader_read_layout)
                vk.pipeline_stage_fragment_shader_bit | vk.pipeline_stage_compute_shader_bit
            else
                vk.pipeline_stage_color_attachment_output_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_transfer),
        );
        const copy = vk.BufferImageCopy{
            .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .image_extent = .{
                .width = snapshot.target.descriptor.width,
                .height = snapshot.target.descriptor.height,
                .depth = 1,
            },
        };
        self.device_functions.cmd_copy_image_to_buffer(
            command_buffer,
            snapshot.image.handle,
            vk.image_layout_transfer_src_optimal,
            snapshot.readback.handle,
            1,
            @ptrCast(&copy),
        );
        const host_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_host_read_bit,
            .buffer = snapshot.readback.handle,
            .offset = 0,
            .size = snapshot.readback.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_host_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&host_barrier),
            0,
            null,
        );
        const back_to_attachment = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_read_bit,
            .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .old_layout = vk.image_layout_transfer_src_optimal,
            .new_layout = vk.image_layout_color_attachment_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_color_attachment_output_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&back_to_attachment),
        );
        try self.submitOneShot(command_buffer);

        const frame = try self.allocator.alloc(u8, frame_bytes);
        defer self.allocator.free(frame);
        try self.readMapped(snapshot.readback, frame);
        self.frame_profile.readback_bytes += frame_bytes;
        self.frame_profile.target_readback_bytes += frame_bytes;
        if (snapshot.target.descriptor.force_destination_alpha_one) {
            forceColorTargetAlphaOne(frame, snapshot.target.format);
        }
        try self.recordGuestColorTarget(snapshot.target, frame);
        self.render_targets.items[index].host_generation = snapshot.gpu_generation;
        self.render_targets.items[index].shader_read_layout = false;

        const colored = countNonzeroTexels(frame, snapshot.target.format.bytes_per_texel);
        self.graphics_probe_colored_pixels = colored;
        if (snapshot.target.format.bytes_per_texel == 4) {
            if (self.frame_dumps == 0 and colored != 0) {
                dumpFramePpm("out\\first-frame.ppm", snapshot.target.descriptor.width, snapshot.target.descriptor.height, frame);
                self.frame_dumps += 1;
            }
            if (colored != 0) switch (self.frame_sequence) {
                32, 64, 128 => {
                    var path_buffer: [64]u8 = undefined;
                    const path: ?[:0]u8 = std.fmt.bufPrintZ(
                        &path_buffer,
                        "out\\render-{d:0>4}.ppm",
                        .{self.frame_sequence},
                    ) catch null;
                    if (path) |name| dumpFramePpm(
                        name.ptr,
                        snapshot.target.descriptor.width,
                        snapshot.target.descriptor.height,
                        frame,
                    );
                },
                else => {},
            };
        } else if (log_verbose_gpu or self.reported_non_rgba_materializations < 4) {
            self.reported_non_rgba_materializations += 1;
            std.debug.print(
                "[vulkan dcb] materialized color target @0x{x} fmt={d} nonzero_texels={d}/{d}\n",
                .{
                    snapshot.target.descriptor.address,
                    snapshot.target.descriptor.format,
                    colored,
                    snapshot.target.descriptor.width * snapshot.target.descriptor.height,
                },
            );
        }
    }

    fn materializeRenderTargetAt(self: *Renderer, address: u64) anyerror!bool {
        for (self.render_targets.items, 0..) |cached, index| {
            if (cached.target.descriptor.address != address) continue;
            try self.materializeRenderTarget(index);
            return true;
        }
        return false;
    }

    /// CB_COLOR_CONTROL.MODE=RESOLVE uses slot 0 as the multisampled source and
    /// slot 1 as the single-sample destination.  Until Vulkan MSAA attachments
    /// are exposed, normal draws retain one representative sample; publishing
    /// that resident image under the resolve destination preserves the fixed-
    /// function data flow used by Unity before its final fullscreen blit.
    fn resolveColorTargets(self: *Renderer, render_state: gpu.resources.RenderState) anyerror!bool {
        if (render_state.color_control.mode != 3) return false;
        const source_descriptor = render_state.color_targets[0] orelse return false;
        const destination_descriptor = render_state.color_targets[1] orelse return false;
        if (source_descriptor.address == destination_descriptor.address) return false;

        const source = try guestColorTarget(source_descriptor);
        const destination = try guestColorTarget(destination_descriptor);
        if (source.descriptor.width != destination.descriptor.width or
            source.descriptor.height != destination.descriptor.height or
            source.format.vulkan != destination.format.vulkan)
        {
            return Error.UnsupportedColorTarget;
        }

        var source_index: ?usize = null;
        for (self.render_targets.items, 0..) |cached, index| {
            if (cached.target.descriptor.address != source.descriptor.address or
                cached.target.descriptor.width != source.descriptor.width or
                cached.target.descriptor.height != source.descriptor.height or
                cached.target.format.vulkan != source.format.vulkan)
            {
                continue;
            }
            source_index = index;
            break;
        }
        const index = source_index orelse return Error.MissingPresentedFrame;
        try self.materializeRenderTarget(index);

        var resolved_index: ?usize = null;
        var resolved_sequence: u64 = 0;
        for (self.completed_frames.items, 0..) |cached, frame_index| {
            if (cached.guest_address != source.descriptor.address or
                cached.width != source.descriptor.width or
                cached.height != source.descriptor.height or
                cached.sequence < resolved_sequence)
            {
                continue;
            }
            resolved_index = frame_index;
            resolved_sequence = cached.sequence;
        }
        const frame_index = resolved_index orelse return Error.MissingPresentedFrame;
        const pixels = try self.allocator.dupe(u8, self.completed_frames.items[frame_index].pixels.items);
        defer self.allocator.free(pixels);
        try self.recordGuestColorTarget(destination, pixels);

        // A destination retained from an earlier frame must not shadow the new
        // deferred resolve when it is immediately sampled as a texture.
        for (self.render_targets.items) |*cached| {
            if (cached.target.descriptor.address != destination.descriptor.address) continue;
            cached.initialized = false;
            cached.gpu_generation = 0;
            cached.host_generation = 0;
        }

        if (self.reported_color_resolves < 4 or log_verbose_gpu) {
            self.reported_color_resolves += 1;
            std.debug.print(
                "[vulkan dcb] color resolve approximated 0x{x} -> 0x{x} {d}x{d} samples={d}\n",
                .{
                    source.descriptor.address,
                    destination.descriptor.address,
                    destination.descriptor.width,
                    destination.descriptor.height,
                    source_descriptor.samples_log2,
                },
            );
        }
        return true;
    }

    fn drawPersistentGraphicsShaders(
        self: *Renderer,
        vertex_words: []const u32,
        fragment_words: []const u32,
        vertex_scalars: []const gpu.ShaderSpirvScalarRegister,
        fragment_scalars: []const gpu.ShaderSpirvScalarRegister,
        pipeline_state: GraphicsPipelineState,
        target: GuestColorTarget,
        depth: ?GuestDepthTarget,
        depth_clear_requested: bool,
        bind_graphics_descriptors: bool,
        draw: GuestDraw,
    ) anyerror!void {
        const target_index = try self.acquireRenderTarget(target);
        try self.transitionRenderTargetToColorAttachment(target_index);
        const cached_snapshot = self.render_targets.items[target_index];
        const frame_bytes = try colorTargetFrameBytes(target);
        const report_checkpoints = !self.reported_first_graphics_draw_checkpoints;
        if (report_checkpoints) std.debug.print(
            "[vulkan dcb] first graphics draw: target ready bytes={d} initialized={any}\n",
            .{ frame_bytes, cached_snapshot.initialized },
        );

        var initial_upload: ?OwnedBuffer = null;
        defer if (initial_upload) |buffer| self.destroyBuffer(buffer);
        if (!cached_snapshot.initialized) {
            const frame = try self.allocator.alloc(u8, frame_bytes);
            defer self.allocator.free(frame);
            const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
            const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
            try self.stageInitialColorTarget(target, reader, frame);
            initial_upload = try self.createBuffer(
                frame_bytes,
                vk.buffer_usage_transfer_src_bit,
                vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
            );
            try self.writeMapped(initial_upload.?, frame);
            self.frame_profile.upload_bytes += frame_bytes;
            self.frame_profile.target_upload_bytes += frame_bytes;
            if (report_checkpoints) std.debug.print("[vulkan dcb] first graphics draw: initial target staged\n", .{});
        }

        var index_upload: ?OwnedBuffer = null;
        defer if (index_upload) |buffer| self.destroyBuffer(buffer);
        if (draw.index_count) |index_count| {
            if (index_count != 0) {
                const index_stride: u64 = if (draw.index_uint32) 4 else 2;
                const index_bytes = std.math.mul(u64, index_count, index_stride) catch
                    return Error.GuestBufferTooLarge;
                if (index_bytes == 0 or index_bytes > maximum_frame_bytes) return Error.GuestBufferTooLarge;
                const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
                const bytes: usize = @intCast(index_bytes);
                const indices = try self.allocator.alloc(u8, bytes);
                defer self.allocator.free(indices);
                if (!memory.read(memory.context, draw.index_address, indices)) return Error.GuestMemoryReadFailed;
                index_upload = try self.createBuffer(
                    bytes,
                    vk.buffer_usage_index_buffer_bit,
                    vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
                );
                try self.writeMapped(index_upload.?, indices);
                self.frame_profile.upload_bytes += bytes;
                self.frame_profile.index_upload_bytes += bytes;
            }
        }

        if (report_checkpoints) std.debug.print(
            "[vulkan dcb] first graphics draw: compiling pipeline vs_words={d} ps_words={d}\n",
            .{ vertex_words.len, fragment_words.len },
        );
        if (report_checkpoints) std.debug.print(
            "[vulkan dcb] first graphics draw: viewport={d}x{d} scissor={d}x{d} discard={d} write=0x{x} blend={d}\n",
            .{
                @as(f32, @bitCast(pipeline_state.viewport_width_bits)),
                @as(f32, @bitCast(pipeline_state.viewport_height_bits)),
                pipeline_state.scissor_width,
                pipeline_state.scissor_height,
                pipeline_state.rasterizer_discard,
                pipeline_state.color_write_mask,
                pipeline_state.blend_enable,
            },
        );
        // A depth attachment changes the render pass a pipeline must be
        // compatible with, so it has to be resolved before the pipeline is
        // looked up rather than at the point the pass begins.
        const depth_index: ?usize = if (depth) |plane| try self.acquireDepthTarget(plane) else null;
        const depth_pass: ?DepthPass = if (depth_index) |index|
            try self.acquireDepthPass(target_index, index)
        else
            null;
        const pass_handle = if (depth_pass) |pass| pass.render_pass else cached_snapshot.render_pass;
        const framebuffer_handle = if (depth_pass) |pass| pass.framebuffer else cached_snapshot.framebuffer;
        const pipeline = try self.getGraphicsPipeline(
            pass_handle,
            pipeline_state,
            vertex_words,
            fragment_words,
        );
        try self.writeGraphicsScalarValues(vertex_scalars, fragment_scalars);
        if (report_checkpoints) std.debug.print("[vulkan dcb] first graphics draw: pipeline ready\n", .{});
        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);

        if (initial_upload) |upload| {
            const to_transfer = vk.ImageMemoryBarrier{
                .source_access_mask = 0,
                .destination_access_mask = vk.access_transfer_write_bit,
                .old_layout = vk.image_layout_undefined,
                .new_layout = vk.image_layout_transfer_dst_optimal,
                .image = cached_snapshot.image.handle,
                .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
            };
            self.device_functions.cmd_pipeline_barrier(
                command_buffer,
                vk.pipeline_stage_top_of_pipe_bit,
                vk.pipeline_stage_transfer_bit,
                0,
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&to_transfer),
            );
            const upload_copy = vk.BufferImageCopy{
                .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
                .image_extent = .{
                    .width = target.descriptor.width,
                    .height = target.descriptor.height,
                    .depth = 1,
                },
            };
            self.device_functions.cmd_copy_buffer_to_image(
                command_buffer,
                upload.handle,
                cached_snapshot.image.handle,
                vk.image_layout_transfer_dst_optimal,
                1,
                @ptrCast(&upload_copy),
            );
            const to_attachment = vk.ImageMemoryBarrier{
                .source_access_mask = vk.access_transfer_write_bit,
                .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
                .old_layout = vk.image_layout_transfer_dst_optimal,
                .new_layout = vk.image_layout_color_attachment_optimal,
                .image = cached_snapshot.image.handle,
                .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
            };
            self.device_functions.cmd_pipeline_barrier(
                command_buffer,
                vk.pipeline_stage_transfer_bit,
                vk.pipeline_stage_color_attachment_output_bit,
                0,
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&to_attachment),
            );
        }

        if (depth_index) |index| {
            self.prepareDepthAttachment(command_buffer, index, depth_clear_requested);
        }
        const begin_info = vk.RenderPassBeginInfo{
            .render_pass = pass_handle,
            .framebuffer = framebuffer_handle,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = pipeline_state.width, .height = pipeline_state.height },
            },
            .clear_value_count = 0,
            .clear_values = undefined,
        };
        self.device_functions.cmd_begin_render_pass(command_buffer, &begin_info, vk.subpass_contents_inline);
        self.device_functions.cmd_bind_pipeline(command_buffer, vk.pipeline_bind_point_graphics, pipeline);
        if (bind_graphics_descriptors or vertex_scalars.len != 0 or fragment_scalars.len != 0) {
            self.device_functions.cmd_bind_descriptor_sets(
                command_buffer,
                vk.pipeline_bind_point_graphics,
                self.compute_pipeline_layout,
                0,
                1,
                @ptrCast(&self.descriptor_set),
                0,
                null,
            );
        }

        if (draw.index_count) |index_count| {
            if (index_count != 0) {
                self.device_functions.cmd_bind_index_buffer(
                    command_buffer,
                    index_upload.?.handle,
                    0,
                    if (draw.index_uint32) vk.index_type_uint32 else vk.index_type_uint16,
                );
                self.device_functions.cmd_draw_indexed(command_buffer, index_count, draw.instance_count, 0, 0, 0);
            }
        } else if (draw.vertex_count != 0) {
            self.device_functions.cmd_draw(command_buffer, draw.vertex_count, draw.instance_count, 0, 0);
        }
        self.device_functions.cmd_end_render_pass(command_buffer);
        try self.submitOneShot(command_buffer);
        if (report_checkpoints) {
            std.debug.print("[vulkan dcb] first graphics draw: submitted\n", .{});
            self.reported_first_graphics_draw_checkpoints = true;
        }

        self.render_target_sequence +%= 1;
        const cached = &self.render_targets.items[target_index];
        cached.initialized = true;
        cached.gpu_generation +%= 1;
        cached.last_used_sequence = self.render_target_sequence;
        self.latest_render_target_index = target_index;
        if (report_checkpoints and self.capture_first_graphics_frame) {
            try self.materializeRenderTarget(target_index);
            std.debug.print(
                "[vulkan dcb] first graphics draw: readback colored_pixels={d}\n",
                .{self.graphics_probe_colored_pixels},
            );
        }
    }

    fn drawGraphicsShaders(
        self: *Renderer,
        vertex_words: []const u32,
        fragment_words: []const u32,
        vertex_scalars: []const gpu.ShaderSpirvScalarRegister,
        fragment_scalars: []const gpu.ShaderSpirvScalarRegister,
        pipeline_state: GraphicsPipelineState,
        guest_target: ?GuestColorTarget,
        depth: ?GuestDepthTarget,
        depth_clear_requested: bool,
        bind_graphics_descriptors: bool,
        validate_diagnostic_color: bool,
        draw: GuestDraw,
    ) anyerror!void {
        if (guest_target) |target| {
            return self.drawPersistentGraphicsShaders(
                vertex_words,
                fragment_words,
                vertex_scalars,
                fragment_scalars,
                pipeline_state,
                target,
                depth,
                depth_clear_requested,
                bind_graphics_descriptors,
                draw,
            );
        }
        const width = pipeline_state.width;
        const height = pipeline_state.height;
        const frame_pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch {
            return Error.UnsupportedColorTarget;
        };
        const frame_bytes = std.math.mul(usize, frame_pixels, 4) catch return Error.UnsupportedColorTarget;
        if (frame_bytes == 0 or frame_bytes > maximum_frame_bytes) return Error.UnsupportedColorTarget;
        var frame = try self.allocator.alloc(u8, frame_bytes);
        defer self.allocator.free(frame);
        var upload: ?OwnedBuffer = null;
        defer if (upload) |buffer| self.destroyBuffer(buffer);
        if (guest_target) |target| {
            if (target.layout.staging_bytes != frame_bytes) return Error.UnsupportedColorTarget;
            const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
            const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
            try target.layout.stage(reader, target.descriptor.address, frame);
            upload = try self.createBuffer(
                frame_bytes,
                vk.buffer_usage_transfer_src_bit,
                vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
            );
            try self.writeMapped(upload.?, frame);
        }
        const color = try self.createImage(
            width,
            height,
            vk.format_r8g8b8a8_unorm,
            vk.image_usage_color_attachment_bit | vk.image_usage_transfer_src_bit |
                (if (guest_target != null) vk.image_usage_transfer_dst_bit else 0),
        );
        defer self.destroyImage(color);

        const view_info = vk.ImageViewCreateInfo{
            .image = color.handle,
            .format = vk.format_r8g8b8a8_unorm,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        var view: vk.ImageView = 0;
        if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
            return Error.ImageViewCreationFailed;
        }
        defer self.device_functions.destroy_image_view(self.device, view, null);

        const render_pass = try self.createGraphicsRenderPass(vk.format_r8g8b8a8_unorm, guest_target != null);
        defer self.device_functions.destroy_render_pass(self.device, render_pass, null);
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = 1,
            .attachments = @ptrCast(&view),
            .width = width,
            .height = height,
        };
        var framebuffer: vk.Framebuffer = 0;
        if (self.device_functions.create_framebuffer(self.device, &framebuffer_info, null, &framebuffer) != vk.success) {
            return Error.FramebufferCreationFailed;
        }
        defer self.device_functions.destroy_framebuffer(self.device, framebuffer, null);

        const pipeline = try self.getGraphicsPipeline(render_pass, pipeline_state, vertex_words, fragment_words);
        const readback = try self.createBuffer(
            frame_bytes,
            vk.buffer_usage_transfer_dst_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(readback);

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        if (upload) |upload_buffer| {
            const transfer_barrier = vk.ImageMemoryBarrier{
                .source_access_mask = 0,
                .destination_access_mask = vk.access_transfer_write_bit,
                .old_layout = vk.image_layout_undefined,
                .new_layout = vk.image_layout_transfer_dst_optimal,
                .image = color.handle,
                .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
            };
            self.device_functions.cmd_pipeline_barrier(
                command_buffer,
                vk.pipeline_stage_top_of_pipe_bit,
                vk.pipeline_stage_transfer_bit,
                0,
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&transfer_barrier),
            );
            const upload_copy = vk.BufferImageCopy{
                .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
                .image_extent = .{ .width = width, .height = height, .depth = 1 },
            };
            self.device_functions.cmd_copy_buffer_to_image(
                command_buffer,
                upload_buffer.handle,
                color.handle,
                vk.image_layout_transfer_dst_optimal,
                1,
                @ptrCast(&upload_copy),
            );
            const attachment_barrier = vk.ImageMemoryBarrier{
                .source_access_mask = vk.access_transfer_write_bit,
                .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
                .old_layout = vk.image_layout_transfer_dst_optimal,
                .new_layout = vk.image_layout_color_attachment_optimal,
                .image = color.handle,
                .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
            };
            self.device_functions.cmd_pipeline_barrier(
                command_buffer,
                vk.pipeline_stage_transfer_bit,
                vk.pipeline_stage_color_attachment_output_bit,
                0,
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&attachment_barrier),
            );
        }
        const clear = vk.ClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
        const begin_info = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = width, .height = height },
            },
            .clear_value_count = if (guest_target == null) 1 else 0,
            .clear_values = @ptrCast(&clear),
        };
        self.device_functions.cmd_begin_render_pass(command_buffer, &begin_info, vk.subpass_contents_inline);
        self.device_functions.cmd_bind_pipeline(command_buffer, vk.pipeline_bind_point_graphics, pipeline);
        if (bind_graphics_descriptors) {
            self.device_functions.cmd_bind_descriptor_sets(
                command_buffer,
                vk.pipeline_bind_point_graphics,
                self.compute_pipeline_layout,
                0,
                1,
                @ptrCast(&self.descriptor_set),
                0,
                null,
            );
        }
        var index_upload: ?OwnedBuffer = null;
        defer if (index_upload) |buffer| self.destroyBuffer(buffer);
        if (draw.index_count) |index_count| {
            if (index_count != 0) {
                const index_stride: u64 = if (draw.index_uint32) 4 else 2;
                const index_bytes = std.math.mul(u64, index_count, index_stride) catch {
                    return Error.GuestBufferTooLarge;
                };
                if (index_bytes == 0 or index_bytes > maximum_frame_bytes) {
                    return Error.GuestBufferTooLarge;
                }
                const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
                const bytes: usize = @intCast(index_bytes);
                const indices = try self.allocator.alloc(u8, bytes);
                defer self.allocator.free(indices);
                if (!memory.read(memory.context, draw.index_address, indices)) {
                    return Error.GuestMemoryReadFailed;
                }
                index_upload = try self.createBuffer(
                    bytes,
                    vk.buffer_usage_index_buffer_bit | vk.buffer_usage_transfer_dst_bit,
                    vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
                );
                try self.writeMapped(index_upload.?, indices);
                self.device_functions.cmd_bind_index_buffer(
                    command_buffer,
                    index_upload.?.handle,
                    0,
                    if (draw.index_uint32) vk.index_type_uint32 else vk.index_type_uint16,
                );
                self.device_functions.cmd_draw_indexed(
                    command_buffer,
                    index_count,
                    draw.instance_count,
                    0,
                    0,
                    0,
                );
            }
        } else if (draw.vertex_count != 0) {
            self.device_functions.cmd_draw(
                command_buffer,
                draw.vertex_count,
                draw.instance_count,
                0,
                0,
            );
        }
        self.device_functions.cmd_end_render_pass(command_buffer);

        const image_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .old_layout = vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_transfer_src_optimal,
            .image = color.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_color_attachment_output_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&image_barrier),
        );
        const copy = vk.BufferImageCopy{
            .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };
        self.device_functions.cmd_copy_image_to_buffer(
            command_buffer,
            color.handle,
            vk.image_layout_transfer_src_optimal,
            readback.handle,
            1,
            @ptrCast(&copy),
        );
        const host_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_host_read_bit,
            .buffer = readback.handle,
            .offset = 0,
            .size = readback.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_host_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&host_barrier),
            0,
            null,
        );
        try self.submitOneShot(command_buffer);
        try self.readMapped(readback, frame);
        if (guest_target) |target| {
            if (target.descriptor.force_destination_alpha_one) forceDestinationAlphaOne(frame);
            try self.recordGuestColorTarget(target, frame);
        }
        if (frame.len == self.graphics_probe_frame.len) @memcpy(&self.graphics_probe_frame, frame);

        const center = (@as(usize, height / 2) * width + width / 2) * 4;
        const corner = frame[0..4];
        const center_pixel = frame[center..][0..4];
        if (validate_diagnostic_color and
            (!std.mem.eql(u8, corner, &.{ 0, 0, 0, 255 }) or
                center_pixel[0] < 200 or center_pixel[1] < 40 or center_pixel[1] > 100 or
                center_pixel[2] > 80 or center_pixel[3] != 255))
        {
            return Error.GraphicsProbeReadbackMismatch;
        }
        var colored: u32 = 0;
        var pixel: usize = 0;
        while (pixel < frame.len) : (pixel += 4) {
            if (frame[pixel] != 0 or frame[pixel + 1] != 0 or frame[pixel + 2] != 0) {
                colored += 1;
            }
        }
        if (validate_diagnostic_color and
            (colored == 0 or colored >= width * height))
        {
            return Error.GraphicsProbeReadbackMismatch;
        }
        self.graphics_probe_colored_pixels = colored;

        if (guest_target) |target| {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] writeback: {d}x{d} @0x{x} colored={d}/{d} corner=({d},{d},{d},{d}) center=({d},{d},{d},{d})\n",
                .{
                    width,
                    height,
                    target.descriptor.address,
                    colored,
                    width * height,
                    corner[0],
                    corner[1],
                    corner[2],
                    corner[3],
                    center_pixel[0],
                    center_pixel[1],
                    center_pixel[2],
                    center_pixel[3],
                },
            );
            // Guest PS often leaves alpha at 0 for premultiplied/unused paths;
            // force opaque so the host window and PPM dump show RGB content.
            makePresentationOpaque(frame);
            // Dump the first non-black guest frame for offline inspection.
            if (self.frame_dumps == 0 and colored != 0) {
                dumpFramePpm("out\\first-frame.ppm", width, height, frame);
                self.frame_dumps += 1;
            }
            // Present immediately so the window shows the render target even if
            // the title never reaches SetFlip (e.g. managed null faults mid-init).
            self.eagerPresentFrame(.{
                .pixels = frame,
                .width = width,
                .height = height,
                .row_pitch_bytes = width * 4,
                .guest_address = target.descriptor.address,
                .flip = .{
                    .video_out_handle = 0,
                    .display_buffer_index = 0,
                    .mode = 0,
                    .argument = 0,
                },
            });
        }
    }

    fn eagerPresentFrame(self: *Renderer, frame: PresentedFrame) void {
        const sink = self.presentation_sink orelse return;
        if (frame.width == 0 or frame.height == 0 or frame.pixels.len == 0) return;
        if (!sink.present(sink.context, frame)) {
            std.debug.print(
                "[vulkan dcb] eager present rejected (err={s})\n",
                .{if (self.last_flip_error) |err| @errorName(err) else "unknown"},
            );
            return;
        }
        self.eager_presents += 1;
        self.presented_frames += 1;
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] eager present ok: {d}x{d} @0x{x} (#{d})\n",
            .{ frame.width, frame.height, frame.guest_address, self.eager_presents },
        );
    }

    /// Lazy writeback: tiles `frame` into the guest allocation `target` names.
    /// Called only when the guest is about to observe the target — at flip,
    /// before a guest readback or a sampled-image staging of that address, or
    /// at a synchronization packet — never after every draw.
    fn commitGuestColorTarget(self: *Renderer, target: GuestColorTarget, frame: []const u8) anyerror!void {
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const allocation_bytes = std.math.cast(usize, target.layout.required_source_bytes) orelse {
            return Error.UnsupportedColorTarget;
        };
        if (allocation_bytes > maximum_frame_bytes) return Error.UnsupportedColorTarget;
        const tiled = try self.allocator.alloc(u8, allocation_bytes);
        defer self.allocator.free(tiled);
        if (!memory.read(memory.context, target.descriptor.address, tiled)) return Error.GuestMemoryReadFailed;
        try target.layout.tile(frame, tiled);
        if (!memory.write(memory.context, target.descriptor.address, tiled)) return Error.GuestMemoryWriteFailed;
        try self.commitExpandedCmask(target);
        self.guest_color_target_writes += 1;
    }

    /// Host rendering publishes ordinary base-surface texels. Mark every
    /// active CMASK block expanded so a later cache miss never re-applies an
    /// obsolete fast clear over those newly written pixels.
    fn commitExpandedCmask(self: *Renderer, target: GuestColorTarget) anyerror!void {
        const descriptor = target.descriptor;
        if (!descriptor.cmask_fast_clear or descriptor.cmask_address == 0 or descriptor.dcc_enabled) return;
        const layout = gpu.CmaskLayout.fromColorTarget(descriptor) catch return;
        const byte_count = std.math.cast(usize, layout.required_bytes) orelse return;
        if (byte_count == 0 or byte_count > maximum_cmask_bytes) return;
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const metadata = try self.allocator.alloc(u8, byte_count);
        defer self.allocator.free(metadata);
        if (!memory.read(memory.context, descriptor.cmask_address, metadata)) return Error.GuestMemoryReadFailed;

        var changed = false;
        for (0..layout.layers) |layer_index| {
            var y: u32 = 0;
            while (y < layout.height) : (y += 8) {
                var x: u32 = 0;
                while (x < layout.width) : (x += 8) {
                    const layer: u32 = @intCast(layer_index);
                    if (try layout.value(metadata, x, y, layer) == 0xf) continue;
                    try layout.setValue(metadata, x, y, layer, 0xf);
                    changed = true;
                }
            }
        }
        if (changed and !memory.write(memory.context, descriptor.cmask_address, metadata)) {
            return Error.GuestMemoryWriteFailed;
        }
    }

    /// Records a completed render in host memory without touching the guest
    /// allocation. The frame is presented from this host copy; the guest copy
    /// is produced by `flushPendingGuestWrites` only when it is actually
    /// needed, so a frame with many draws costs one tile+writeback instead of
    /// one per draw.
    fn recordGuestColorTarget(self: *Renderer, target: GuestColorTarget, frame: []const u8) anyerror!void {
        var frame_index: ?usize = null;
        for (self.completed_frames.items, 0..) |cached, index| {
            if (cached.guest_address == target.descriptor.address) {
                frame_index = index;
                break;
            }
        }
        if (frame_index == null) {
            if (self.completed_frames.items.len < maximum_completed_frames) {
                try self.completed_frames.append(self.allocator, .{});
                frame_index = self.completed_frames.items.len - 1;
            } else {
                // Evicting a slot whose writeback is still pending would lose
                // the rendered frame for good; flush it before reuse.
                var oldest_index: usize = 0;
                for (self.completed_frames.items[1..], 1..) |cached, index| {
                    if (cached.sequence < self.completed_frames.items[oldest_index].sequence) oldest_index = index;
                }
                const evicted = &self.completed_frames.items[oldest_index];
                if (evicted.needs_writeback) {
                    if (evicted.target) |evicted_target| {
                        try self.commitGuestColorTarget(evicted_target, evicted.pixels.items);
                    }
                    evicted.needs_writeback = false;
                }
                frame_index = oldest_index;
            }
        }
        const cached = &self.completed_frames.items[frame_index.?];
        cached.pixels.clearRetainingCapacity();
        try cached.pixels.appendSlice(self.allocator, frame);
        self.frame_sequence +%= 1;
        cached.width = target.descriptor.width;
        cached.height = target.descriptor.height;
        cached.guest_address = target.descriptor.address;
        cached.sequence = self.frame_sequence;
        cached.target = target;
        cached.needs_writeback = true;
        self.latest_frame_index = frame_index;
    }

    /// Publishes every deferred guest writeback. Cheap when nothing is
    /// pending, which is the common case between synchronization packets.
    pub fn flushPendingGuestWrites(self: *Renderer) anyerror!void {
        var target_index: usize = 0;
        while (target_index < self.render_targets.items.len) : (target_index += 1) {
            try self.materializeRenderTarget(target_index);
        }
        for (self.completed_frames.items) |*cached| {
            if (!cached.needs_writeback) continue;
            const target = cached.target orelse continue;
            try self.commitGuestColorTarget(target, cached.pixels.items);
            cached.needs_writeback = false;
        }
    }

    /// Publishes only the deferred writeback for one guest address, used
    /// before guest memory at that address is staged or read.
    fn flushPendingGuestWrite(self: *Renderer, address: u64, visible_bytes: usize) anyerror!void {
        try self.flushGuestStorageRange(address, visible_bytes);
        _ = try self.materializeRenderTargetAt(address);
        _ = try self.materializeHtileTargetAt(address, visible_bytes);
        for (self.completed_frames.items) |*cached| {
            if (!cached.needs_writeback or cached.guest_address != address) continue;
            const target = cached.target orelse continue;
            try self.commitGuestColorTarget(target, cached.pixels.items);
            cached.needs_writeback = false;
            return;
        }
    }

    fn drawGraphicsProbe(self: *Renderer) anyerror!void {
        return self.drawGraphicsShaders(
            &graphics_probe_vertex_spirv,
            &graphics_probe_fragment_spirv,
            &.{},
            &.{},
            GraphicsPipelineState.default(graphics_probe_width, graphics_probe_height),
            null,
            null,
            false,
            false,
            true,
            .{ .vertex_count = 3 },
        );
    }

    fn drawGuestGraphics(
        self: *Renderer,
        state: *const gpu.State,
        draw: GuestDraw,
        vertex_stage: gpu.resources.ShaderStage,
        target_override: ?gpu.resources.ColorTarget,
    ) anyerror!void {
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const render_state = gpu.resources.decodeRenderState(state);
        if (!self.reported_first_scissor_state) {
            std.debug.print(
                "[vulkan dcb] first scissor state decoded={any} screen={any}/{any} window={any}/{any} generic={any}/{any} viewport={any}/{any} mode={any}\n",
                .{
                    render_state.scissor,
                    state.readRegister(.context, 0x00c),
                    state.readRegister(.context, 0x00d),
                    state.readRegister(.context, 0x081),
                    state.readRegister(.context, 0x082),
                    state.readRegister(.context, 0x090),
                    state.readRegister(.context, 0x091),
                    state.readRegister(.context, 0x094),
                    state.readRegister(.context, 0x095),
                    state.readRegister(.context, 0x292),
                },
            );
            self.reported_first_scissor_state = true;
        }
        // The current Vulkan attachment path still renders colour target 0
        // only. Preserve depth resource semantics meanwhile: exact HTILE fast
        // clears are materialized into the base depth/stencil allocations so
        // later CPU or texture reads never observe stale tiles.
        if (render_state.depth_target) |depth| {
            self.resolveHtileTarget(depth) catch |err| {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] HTILE resolve failed @0x{x}: {s}\n",
                    .{ depth.htile_address, @errorName(err) },
                );
            };
        }
        // Depth is attached only when the guest both binds a usable allocation
        // and asks for the test or the write. A title that leaves stale DB
        // registers bound while drawing its UI would otherwise pay for an
        // attachment nothing reads. Multi-MRT output is still ignored: the
        // attachment path carries one colour target.
        const depth_wanted = render_state.depth_control.test_enabled or
            render_state.depth_control.write_enabled or
            render_state.depth_control.clear_enabled;
        const depth_plane: ?GuestDepthTarget = if (depth_wanted)
            if (render_state.depth_target) |bound| guestDepthTarget(bound) else null
        else
            null;
        if (target_override == null and render_state.active_color_count != 1) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw: ignoring extra colour targets (colors={d})\n",
                .{render_state.active_color_count},
            );
        }
        if (depth_wanted and depth_plane == null) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw: depth requested but not representable (bound={any})\n",
                .{render_state.depth_target != null},
            );
        }
        var target_descriptor = target_override;
        if (target_descriptor == null) {
            for (render_state.color_targets) |candidate| {
                const target = candidate orelse continue;
                if (!target.isActive()) continue;
                target_descriptor = target;
                break;
            }
        }
        const guest_descriptor = target_descriptor orelse return Error.MissingColorTarget;
        if (guest_descriptor.samples_log2 != 0 or guest_descriptor.fragments_log2 != 0) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] approximating MSAA color target samples={d} frags={d} with one host sample\n",
                .{ guest_descriptor.samples_log2, guest_descriptor.fragments_log2 },
            );
        }
        const target = try guestColorTarget(guest_descriptor);
        const descriptor = target.descriptor;
        // The persistent target path resolves uniform DCC and CMASK-only
        // clear/expanded blocks during its initial upload. FMASK and other
        // compressed states still fall back to raw tiles rather than blocking
        // otherwise usable title draws.
        if (descriptor.dcc_enabled or descriptor.cmask_fast_clear or descriptor.fmask_compression) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw metadata dcc={any} cmask={any} fmask={any} fmt={d}\n",
                .{
                    descriptor.dcc_enabled,
                    descriptor.cmask_fast_clear,
                    descriptor.fmask_compression,
                    descriptor.format,
                },
            );
        }
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] draw color format={d} number={d} -> vk={d} bytes_per_texel={d}\n",
            .{ descriptor.format, descriptor.number_type, target.format.vulkan, target.format.bytes_per_texel },
        );
        var pipeline_state = try guestGraphicsState(&render_state, descriptor);
        pipeline_state.color_attachment_format = target.format.vulkan;
        pipeline_state.topology = guestPrimitiveTopology(render_state.primitive_type, draw);
        if (depth_plane) |plane| {
            pipeline_state.depth_attachment_format = plane.format;
            pipeline_state.depth_test_enable = @intFromBool(render_state.depth_control.test_enabled);
            pipeline_state.depth_write_enable = @intFromBool(render_state.depth_control.write_enabled);
            pipeline_state.depth_compare_operation =
                depthCompareOperation(render_state.depth_control.compare_function);
        }
        const vertex_address = vertex_stage.programAddress(state) orelse {
            return Error.MissingGraphicsProgram;
        };
        const fragment_address = gpu.resources.ShaderStage.pixel.programAddress(state) orelse {
            return Error.MissingGraphicsProgram;
        };
        if (self.flip_callbacks == 240) {
            std.debug.print(
                "[vulkan dcb] draw trace next_flip={d} draw={d} target=0x{x} VS=0x{x} PS=0x{x} indices={any} vertices={d} viewport={d}x{d} scissor={d},{d}+{d}x{d} discard={d} write=0x{x} blend={d}\n",
                .{
                    self.flip_callbacks + 1,
                    self.frame_profile.draws,
                    descriptor.address,
                    vertex_address,
                    fragment_address,
                    draw.index_count,
                    draw.vertex_count,
                    @as(f32, @bitCast(pipeline_state.viewport_width_bits)),
                    @as(f32, @bitCast(pipeline_state.viewport_height_bits)),
                    pipeline_state.scissor_x,
                    pipeline_state.scissor_y,
                    pipeline_state.scissor_width,
                    pipeline_state.scissor_height,
                    pipeline_state.rasterizer_discard,
                    pipeline_state.color_write_mask,
                    pipeline_state.blend_enable,
                },
            );
        }
        const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
        const vertex_analysis = try self.analyzedProgram(reader, vertex_address);
        const fragment_analysis = try self.analyzedProgram(reader, fragment_address);
        var vertex_export_mask: u64 = 0;
        var vertex_parameter_mask: u32 = 0;
        for (vertex_analysis.program.instructions.items) |inst| {
            if (inst.opcode != .exp) continue;
            vertex_export_mask |= @as(u64, 1) << inst.export_target;
            if (inst.export_target >= 0x20) {
                vertex_parameter_mask |= @as(u32, 1) << @intCast(inst.export_target - 0x20);
            }
        }
        var fragment_attribute_mask: u32 = 0;
        for (fragment_analysis.program.instructions.items) |inst| {
            switch (inst.opcode) {
                .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => {
                    if (inst.src1.kind == .integer_inline_constant and inst.src1.value < 32) {
                        fragment_attribute_mask |= @as(u32, 1) << @intCast(inst.src1.value);
                    }
                },
                else => {},
            }
        }
        var fragment_input_controls: [32]u32 = undefined;
        var mapped_fragment_attribute_mask: u32 = 0;
        var fragment_parameter_mask: u32 = 0;
        for (0..fragment_input_controls.len) |attribute| {
            const control = state.readRegister(.context, 0x191 + @as(u32, @intCast(attribute))) orelse
                @as(u32, @intCast(attribute));
            fragment_input_controls[attribute] = control;
            const attribute_bit = @as(u32, 1) << @intCast(attribute);
            if (fragment_attribute_mask & attribute_bit == 0) continue;
            const parameter: u5 = @truncate(control);
            const parameter_bit = @as(u32, 1) << parameter;
            mapped_fragment_attribute_mask |= parameter_bit;
            if (vertex_parameter_mask & parameter_bit != 0) {
                fragment_parameter_mask |= attribute_bit;
            }
        }
        // NGG export shaders communicate through LDS and therefore expose no
        // ordinary PARAM EXP before their continuation is implemented. For the
        // common single-PARAM fullscreen pass, pair the guest PS with the probe
        // VS's explicit UV location instead of synthesizing interpolation in PS.
        var probe_parameter_mask: u32 = if (vertex_parameter_mask == 0 and fragment_attribute_mask == 1) 1 else 0;
        if (probe_parameter_mask != 0) fragment_input_controls[0] = 0;
        var paired_parameter_mask = if (probe_parameter_mask != 0)
            probe_parameter_mask
        else
            fragment_parameter_mask;
        const trace_interface = self.flip_callbacks == 240;
        if (trace_interface or
            (self.reported_interface_pairs < 2 and
                (self.last_interface_vertex_address != vertex_address or
                    self.last_interface_fragment_address != fragment_address)))
        {
            std.debug.print(
                "[vulkan dcb] shader interface VS=0x{x} exports=0x{x} params=0x{x} PS=0x{x} attrs=0x{x}->params=0x{x}\n",
                .{ vertex_address, vertex_export_mask, vertex_parameter_mask, fragment_address, fragment_attribute_mask, mapped_fragment_attribute_mask },
            );
            var remaining_attributes = fragment_attribute_mask;
            while (remaining_attributes != 0) {
                const attribute: u5 = @intCast(@ctz(remaining_attributes));
                const control = fragment_input_controls[attribute];
                std.debug.print(
                    "  PS attr{d} -> PARAM{d} cntl=0x{x} flat={any}\n",
                    .{ attribute, control & 0x1f, control, control & 0x400 != 0 },
                );
                remaining_attributes &= remaining_attributes - 1;
            }
            if (!trace_interface) {
                self.last_interface_vertex_address = vertex_address;
                self.last_interface_fragment_address = fragment_address;
                self.reported_interface_pairs += 1;
            }
        }
        const vertex_header = if (memory.shader_header) |resolve|
            resolve(memory.context, vertex_address)
        else
            null;
        if (vertex_header == null and memory.shader_header != null) {
            // Registry miss: dump nearby entries once to diagnose mapping gaps.
            std.debug.print(
                "[vulkan dcb] no shader header for VS program 0x{x} stage={s}\n",
                .{ vertex_address, @tagName(vertex_stage) },
            );
        }
        const fragment_header = if (memory.shader_header) |resolve|
            resolve(memory.context, fragment_address)
        else
            null;
        const vertex_bindings = try gpu.ShaderBindings.capture(state, vertex_stage, vertex_header, reader);
        const fragment_bindings = try gpu.ShaderBindings.capture(state, .pixel, fragment_header, reader);
        const resource_started = hostTimestampNs();
        var graphics_resources = try self.prepareGraphicsResources(
            &fragment_bindings,
            reader,
            fragment_analysis,
        );
        self.frame_profile.graphics_resource_ns +|= elapsedHostNanoseconds(resource_started);
        defer graphics_resources.deinit(self);
        if (self.flip_callbacks == 240) {
            for (graphics_resources.mappings[0..graphics_resources.mapping_count]) |mapping| {
                const sampled = graphics_resources.descriptors[@intCast(mapping.descriptor_index)];
                std.debug.print(
                    "[vulkan dcb] traced sampled image draw={d} slot={d} addr=0x{x} {d}x{d} pitch={d} fmt={d} tile={s}\n",
                    .{
                        self.frame_profile.draws,
                        mapping.descriptor_index,
                        sampled.address,
                        sampled.width,
                        sampled.height,
                        sampled.pitch,
                        sampled.unified_format,
                        @tagName(sampled.tile_mode),
                    },
                );
            }
        }

        // Full scalar evaluation (not only the straight prolog cut): vertex
        // programs interleave SMEM loads after a few VALU ops. Preserve each
        // recovered load at its producer PC; a final SGPR snapshot is invalid
        // for NGG shaders which reuse the same registers many times.
        const vertex_provenance_started = hostTimestampNs();
        const vertex_scalar = gpu.scalar_provenance.evaluateDecodedResourceState(
            reader,
            &vertex_bindings,
            vertex_analysis.program.instructions.items,
        );
        self.frame_profile.scalar_provenance_ns +|= elapsedHostNanoseconds(vertex_provenance_started);
        const vertex_scalar_end: u32 = 0x0010_0000;
        var vertex_scalar_regs: [gpu.scalar_provenance.maximum_scalar_specializations]gpu.ShaderSpirvScalarRegister = undefined;
        var vertex_scalar_count = collectScalarLoadSpecializations(&vertex_scalar, &vertex_scalar_regs);
        // NGG/export programs often address USER_DATA as s0.. even when the
        // capture table records scalar_user_data_base=8 for the ES bank. Seed
        // the raw USER_DATA window at s0 so s3.. are not left undefined.
        vertex_scalar_count = mergeUserDataScalars(
            &vertex_bindings,
            0,
            &vertex_scalar_regs,
            vertex_scalar_count,
        );
        // Also seed at the hardware base (s8 for export_shader).
        if (vertex_bindings.scalar_user_data_base != 0) {
            vertex_scalar_count = mergeUserDataScalars(
                &vertex_bindings,
                vertex_bindings.scalar_user_data_base,
                &vertex_scalar_regs,
                vertex_scalar_count,
            );
        }
        // Recover attribute V#s from the AGC vertex buffer table into the SGPRs
        // the VS MUBUF instructions name (typically s4 for Unity NGG).
        var vertex_scalar_mut = vertex_scalar;
        vertex_scalar_count = seedVertexBufferScalars(
            &vertex_bindings,
            reader,
            vertex_analysis,
            &vertex_scalar_regs,
            vertex_scalar_count,
            &vertex_scalar_mut,
        );

        const fragment_provenance_started = hostTimestampNs();
        const fragment_scalar = gpu.scalar_provenance.evaluateDecodedResourceState(
            reader,
            &fragment_bindings,
            fragment_analysis.program.instructions.items,
        );
        self.frame_profile.scalar_provenance_ns +|= elapsedHostNanoseconds(fragment_provenance_started);
        const fragment_scalar_end: u32 = 0x0010_0000;
        var fragment_scalar_regs: [gpu.scalar_provenance.maximum_scalar_specializations]gpu.ShaderSpirvScalarRegister = undefined;
        var fragment_scalar_count = collectScalarLoadSpecializations(&fragment_scalar, &fragment_scalar_regs);
        fragment_scalar_count = mergeUserDataScalars(
            &fragment_bindings,
            fragment_bindings.scalar_user_data_base,
            &fragment_scalar_regs,
            fragment_scalar_count,
        );
        // T#/S# descriptor payloads select host descriptor-array elements;
        // they are not shader constants. Specializing their changing guest
        // addresses creates a new Vulkan pipeline for every streamed texture.
        for (graphics_resources.mappings[0..graphics_resources.mapping_count]) |mapping| {
            fragment_scalar_count = removeScalarRegisterRange(
                &fragment_scalar_regs,
                fragment_scalar_count,
                mapping.resource_sgpr,
                8,
            );
            fragment_scalar_count = removeScalarRegisterRange(
                &fragment_scalar_regs,
                fragment_scalar_count,
                mapping.sampler_sgpr,
                4,
            );
        }

        // Attribute / constant buffer MUBUF in the vertex program needs the
        // same storage-descriptor array as compute. Missing V#s are non-fatal:
        // translate without storage and skip MUBUF rather than abort the draw.
        var vertex_storage = self.prepareComputeResources(
            &vertex_bindings,
            reader,
            vertex_analysis,
            &vertex_scalar_mut,
            vertex_scalar_end,
            null,
        ) catch |err| blk: {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] vertex storage incomplete: {s}; translating without buffers\n",
                .{@errorName(err)},
            );
            break :blk ComputeResources{};
        };
        // V# payloads are runtime descriptor data, not shader constants.  The
        // resource preparation above has already decoded them and assigned
        // stable host descriptor slots.  Leaving their guest addresses in the
        // scalar specialization bakes each streamed vertex buffer into SPIR-V,
        // so sprite-heavy games build a fresh Vulkan pipeline for nearly every
        // draw and again every frame.
        for (vertex_storage.mappings[0..vertex_storage.mapping_count]) |mapping| {
            vertex_scalar_count = removeScalarRegisterRange(
                &vertex_scalar_regs,
                vertex_scalar_count,
                mapping.resource_sgpr,
                4,
            );
        }
        // Detect the planar NV12 conversion layout so its visible width and
        // allocation pitch can be handled without affecting ordinary sampled
        // draws. This Unity pass has a complete four-vertex guest VS; its
        // constants contain the required 1920/2048 U scale, so it must not be
        // replaced by the procedural fallback triangle.
        const planar_video_pass = graphics_resources.image_count == 2 and
            graphics_resources.descriptors[0].tile_mode.isLinear() and
            graphics_resources.descriptors[0].unified_format == 1 and
            // AvPlayer exposes the visible width separately from the NV12
            // allocation pitch. Unity consequently describes the luma plane
            // as 2048 wide for a 1920-pixel movie. Accept that right-hand
            // padding here; requiring exact equality silently disabled the
            // canonical fullscreen VS and left the video pass black.
            graphics_resources.descriptors[0].width >= descriptor.width and
            graphics_resources.descriptors[0].width - descriptor.width < 256 and
            graphics_resources.descriptors[0].pitch == graphics_resources.descriptors[0].width and
            graphics_resources.descriptors[0].height == descriptor.height and
            graphics_resources.descriptors[1].tile_mode.isLinear() and
            graphics_resources.descriptors[1].unified_format == 14 and
            graphics_resources.descriptors[1].width * 2 == graphics_resources.descriptors[0].width and
            graphics_resources.descriptors[1].height * 2 == descriptor.height;
        if (planar_video_pass and !self.reported_planar_video_pass) {
            std.debug.print(
                "[vulkan dcb] planar video pass target=0x{x} {d}x{d} luma={d}x{d}/pitch={d}\n",
                .{
                    descriptor.address,
                    descriptor.width,
                    descriptor.height,
                    graphics_resources.descriptors[0].width,
                    graphics_resources.descriptors[0].height,
                    graphics_resources.descriptors[0].pitch,
                },
            );
            self.reported_planar_video_pass = true;
        }
        if (planar_video_pass) {
            self.markVideoSurface(target.descriptor.address);
            self.video_surface_last_flip = self.flip_callbacks;
            try self.emulatePlanarVideoPass(
                memory,
                target,
                graphics_resources.descriptors[0],
                graphics_resources.descriptors[1],
            );
            return;
        }
        if (graphics_resources.image_count == 1 and
            draw.index_count != null and draw.index_count.? == 6 and
            matchesFullscreenSampleBlit(fragment_analysis.program.instructions.items))
        {
            if (try self.emulateFullscreenSampleBlit(
                memory,
                target,
                graphics_resources.descriptors[0],
            )) return;
        }
        if (fragment_attribute_mask == 1 and vertex_storage.mapping_count == 0) {
            probe_parameter_mask = 1;
            fragment_input_controls[0] = 0;
            paired_parameter_mask = 1;
        }
        // prepareComputeResources soft-skips missing V#s; rebuild its scalar
        // list from the seeded specialization so SPIR-V and staging agree.
        if (vertex_storage.scalar_count == 0 and vertex_scalar_count != 0) {
            // already filled from evaluation; merge seeds into result scalars
        }
        for (vertex_scalar_regs[0..vertex_scalar_count]) |seeded| {
            var found = false;
            for (vertex_storage.scalar_registers[0..vertex_storage.scalar_count]) |*entry| {
                if (entry.register == seeded.register and entry.producer_pc == seeded.producer_pc) {
                    entry.value = seeded.value;
                    found = true;
                    break;
                }
            }
            if (!found and vertex_storage.scalar_count < vertex_storage.scalar_registers.len) {
                vertex_storage.scalar_registers[vertex_storage.scalar_count] = seeded;
                vertex_storage.scalar_count += 1;
            }
        }
        if (!self.reported_vertex_storage_bindings) {
            std.debug.print("[vulkan dcb] first vertex storage mappings={d}\n", .{vertex_storage.mapping_count});
            for (vertex_storage.mappings[0..vertex_storage.mapping_count]) |mapping| {
                const slot: usize = @intCast(mapping.descriptor_index);
                std.debug.print(
                    "  pc={any} V#s{d} slot={d} addr=0x{x} size=0x{x} stride={d} fmt={d} dst={any} soffset={any}\n",
                    .{
                        mapping.instruction_pc,
                        mapping.resource_sgpr,
                        mapping.descriptor_index,
                        vertex_storage.addresses[slot],
                        vertex_storage.sizes[slot],
                        mapping.stride,
                        mapping.unified_format,
                        mapping.dst_select,
                        mapping.soffset_value,
                    },
                );
            }
            self.reported_vertex_storage_bindings = true;
        }
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] vertex storage: mappings={d} scalars={d}\n",
            .{ vertex_storage.mapping_count, vertex_storage.scalar_count },
        );
        if (self.shouldReportVertexResources(vertex_address)) {
            std.debug.print(
                "[vulkan dcb] vertex resources program=0x{x} mappings={d} scalars={d} index=0x{x}/{any} vertices={any} cfg={d}/{d} back={d}\n",
                .{
                    vertex_address,
                    vertex_storage.mapping_count,
                    vertex_storage.scalar_count,
                    draw.index_address,
                    draw.index_count,
                    draw.vertex_count,
                    vertex_analysis.graph.blocks.items.len,
                    vertex_analysis.graph.selections.items.len,
                    vertex_analysis.graph.back_edge_count,
                },
            );
            for (vertex_storage.mappings[0..vertex_storage.mapping_count]) |mapping| {
                const slot: usize = @intCast(mapping.descriptor_index);
                std.debug.print(
                    "  pc={any} V#s{d} slot={d} addr=0x{x} size=0x{x} stride={d} fmt={d} dst={any} soffset={any} vertex_index={any}\n",
                    .{
                        mapping.instruction_pc,
                        mapping.resource_sgpr,
                        mapping.descriptor_index,
                        vertex_storage.addresses[slot],
                        vertex_storage.sizes[slot],
                        mapping.stride,
                        mapping.unified_format,
                        mapping.dst_select,
                        mapping.soffset_value,
                        mapping.use_vertex_index,
                    },
                );
                if (mapping.use_vertex_index) {
                    var first_record: [8]u32 = undefined;
                    if (reader.readWords(vertex_storage.addresses[slot], &first_record)) |_| {
                        std.debug.print(
                            "    first={x:0>8} {x:0>8} {x:0>8} {x:0>8} as_f32={d:.3},{d:.3},{d:.3},{d:.3}\n",
                            .{
                                first_record[0],
                                first_record[1],
                                first_record[2],
                                first_record[3],
                                @as(f32, @bitCast(first_record[0])),
                                @as(f32, @bitCast(first_record[1])),
                                @as(f32, @bitCast(first_record[2])),
                                @as(f32, @bitCast(first_record[3])),
                            },
                        );
                    } else |_| {}
                }
            }
            if (draw.index_address != 0 and draw.index_count != null and draw.index_count.? != 0) {
                var index_bytes: [16]u8 = undefined;
                if (reader.read(draw.index_address, &index_bytes)) |_| {
                    std.debug.print("  indices", .{});
                    var index: usize = 0;
                    while (index < index_bytes.len) : (index += 2) {
                        std.debug.print(" {d}", .{std.mem.readInt(u16, index_bytes[index..][0..2], .little)});
                    }
                    std.debug.print("\n", .{});
                } else |_| {}
            }
            dumpWideScalarLoads(vertex_scalar_regs[0..vertex_scalar_count]);
            dumpShaderHead(vertex_analysis, vertex_analysis.program.instructions.items.len);
        }

        // Pixel shaders use MUBUF/TBUFFER for constant and structured data as
        // well as sampled images.  Keep their descriptor slots disjoint from
        // the vertex resources already staged for this draw.
        var fragment_scalar_mut = fragment_scalar;
        var fragment_storage = self.prepareComputeResources(
            &fragment_bindings,
            reader,
            fragment_analysis,
            &fragment_scalar_mut,
            fragment_scalar_end,
            &vertex_storage,
        ) catch |err| blk: {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] fragment storage incomplete: {s}; translating without buffers\n",
                .{@errorName(err)},
            );
            break :blk ComputeResources{};
        };
        // Unity PS loads color scales and matrices through s_buffer. Identity
        // constants are only a fallback for a genuinely missing V#: once the
        // constant buffer is staged, specializing those destinations would
        // suppress the real loads and turn complex post-processing black.
        if (fragment_storage.mapping_count == 0) {
            fragment_scalar_count = ensureIdentityFragmentScale(
                &fragment_scalar_regs,
                fragment_scalar_count,
            );
        }
        for (fragment_storage.mappings[0..fragment_storage.mapping_count]) |mapping| {
            fragment_scalar_count = removeScalarRegisterRange(
                &fragment_scalar_regs,
                fragment_scalar_count,
                mapping.resource_sgpr,
                4,
            );
        }
        if (!self.reported_fragment_storage_bindings) {
            std.debug.print("[vulkan dcb] first fragment storage mappings={d}\n", .{fragment_storage.mapping_count});
            self.reported_fragment_storage_bindings = true;
        }
        if (self.shouldReportFragmentResources(fragment_address)) {
            std.debug.print(
                "[vulkan dcb] fragment resources program=0x{x} sampled={d} storage={d} scalars={d} loads={d} params=0x{x}\n",
                .{
                    fragment_address,
                    graphics_resources.mapping_count,
                    fragment_storage.mapping_count,
                    fragment_scalar_count,
                    fragment_scalar.load_count,
                    paired_parameter_mask,
                },
            );
            for (graphics_resources.mappings[0..graphics_resources.mapping_count]) |mapping| {
                const sampled_descriptor = graphics_resources.descriptors[@intCast(mapping.descriptor_index)];
                std.debug.print(
                    "  image T#s{d} S#s{d} slot={d} addr=0x{x} {d}x{d} pitch={d} fmt={d} tile={s}\n",
                    .{
                        mapping.resource_sgpr,
                        mapping.sampler_sgpr,
                        mapping.descriptor_index,
                        sampled_descriptor.address,
                        sampled_descriptor.width,
                        sampled_descriptor.height,
                        sampled_descriptor.pitch,
                        sampled_descriptor.unified_format,
                        @tagName(sampled_descriptor.tile_mode),
                    },
                );
            }
            for (fragment_storage.mappings[0..fragment_storage.mapping_count]) |mapping| {
                std.debug.print(
                    "  buffer pc={any} V#s{d} slot={d} stride={d} soffset={any}\n",
                    .{
                        mapping.instruction_pc,
                        mapping.resource_sgpr,
                        mapping.descriptor_index,
                        mapping.stride,
                        mapping.soffset_value,
                    },
                );
            }
            dumpScalarRegisters(fragment_scalar_regs[0..fragment_scalar_count]);
            dumpShaderHead(fragment_analysis, fragment_analysis.program.instructions.items.len);
        }

        const fragment_translate_started = hostTimestampNs();
        var fragment_module = fragment_analysis.translateSpirv(self.allocator, .{
            .stage = .fragment,
            // FragCoord is measured in visible render-target pixels. Dividing
            // X by the NV12 allocation pitch (2048 for a 1920-wide movie)
            // maps the last visible pixel to the last visible luma column and
            // avoids sampling the decoder's right-hand padding.
            .fragment_extent = if (planar_video_pass)
                .{ graphics_resources.descriptors[0].width, target.descriptor.height }
            else
                .{ target.descriptor.width, target.descriptor.height },
            .sampled_images = graphics_resources.mappings[0..graphics_resources.mapping_count],
            .storage_buffers = fragment_storage.mappings[0..fragment_storage.mapping_count],
            .parameter_mask = paired_parameter_mask,
            .fragment_input_controls = &fragment_input_controls,
            .infer_fragment_parameter_mask = false,
            .descriptor_array_length = maximum_storage_descriptors,
            .scalar_registers = fragment_scalar_regs[0..fragment_scalar_count],
            .dynamic_scalar_binding = if (fragment_scalar_count != 0) .{
                .binding = dynamic_scalar_descriptor_binding,
                .value_base = dynamic_scalar_words_per_stage,
            } else null,
            .specialized_scalar_prefix_end = fragment_scalar_end,
        }) catch |err| {
            if (self.shouldReportShaderFailure(fragment_address, .pixel, err)) {
                std.debug.print(
                    "[vulkan dcb] fragment program 0x{x}: {d} instructions, translate={s} scalars={d} end=0x{x}\n",
                    .{
                        fragment_address,
                        fragment_analysis.program.instructions.items.len,
                        @errorName(err),
                        fragment_scalar_count,
                        fragment_scalar_end,
                    },
                );
                dumpShaderHead(fragment_analysis, 16);
                dumpScalarRegisters(fragment_scalar_regs[0..fragment_scalar_count]);
            }
            return err;
        };
        self.frame_profile.shader_translate_ns +|= elapsedHostNanoseconds(fragment_translate_started);
        defer fragment_module.deinit(self.allocator);
        if (self.flip_callbacks == 240 and fragment_module.used_control_flow_fallback) {
            std.debug.print("[vulkan dcb] traced fragment program 0x{x} uses linear control-flow fallback\n", .{fragment_address});
        }
        var texture_probe_module: ?rdna2.spirv.Module = null;
        defer if (texture_probe_module) |*module| module.deinit(self.allocator);
        if (self.force_probe_fragment_texture and graphics_resources.mapping_count != 0) {
            texture_probe_module = try buildTextureProbeFragmentSpirv(
                self.allocator,
                graphics_resources.mappings[0],
                .{ target.descriptor.width, target.descriptor.height },
            );
        }
        var parameter_probe_module: ?rdna2.spirv.Module = null;
        defer if (parameter_probe_module) |*module| module.deinit(self.allocator);
        if (self.force_probe_fragment_parameter) {
            parameter_probe_module = try buildParameterProbeFragmentSpirv(self.allocator);
        }
        var ui_probe_module: ?rdna2.spirv.Module = null;
        defer if (ui_probe_module) |*module| module.deinit(self.allocator);
        if (self.force_probe_fragment_ui and graphics_resources.mapping_count != 0) {
            ui_probe_module = try buildUiProbeFragmentSpirv(
                self.allocator,
                graphics_resources.mappings[0],
                .{ target.descriptor.width, target.descriptor.height },
            );
        }
        const fragment_words = if (self.force_probe_fragment)
            graphics_probe_fragment_spirv[0..]
        else if (texture_probe_module) |module|
            module.words
        else if (parameter_probe_module) |module|
            module.words
        else if (ui_probe_module) |module|
            module.words
        else
            fragment_module.words;

        // Procedural draws deliberately have no V# mappings: fullscreen NGG
        // programs synthesize their rectangle from the system vertex index.
        // Attempt every guest VS unless the paired pixel shader explicitly
        // requires our video/UV probe. Missing individual buffers lower as
        // null resources, so they no longer justify replacing the whole stage.
        const try_guest_vs = probe_parameter_mask == 0;
        if (try_guest_vs) {
            const vertex_translate_started = hostTimestampNs();
            if (vertex_analysis.translateSpirv(self.allocator, .{
                .stage = .vertex,
                // The PS5 NGG/export ABI supplies S_NGG_VERTEX_INDEX in v5;
                // ordinary VS programs retain the legacy v0 convention.
                .vertex_index_vgpr = if (vertex_stage == .export_shader) 5 else 0,
                .scalar_registers = vertex_scalar_regs[0..vertex_scalar_count],
                .dynamic_scalar_binding = if (vertex_scalar_count != 0) .{
                    .binding = dynamic_scalar_descriptor_binding,
                    .value_base = 0,
                } else null,
                .specialized_scalar_prefix_end = vertex_scalar_end,
                .storage_buffers = vertex_storage.mappings[0..vertex_storage.mapping_count],
                .descriptor_array_length = maximum_storage_descriptors,
            })) |vertex_module_owned| {
                self.frame_profile.shader_translate_ns +|= elapsedHostNanoseconds(vertex_translate_started);
                var vertex_module = vertex_module_owned;
                defer vertex_module.deinit(self.allocator);
                if (self.flip_callbacks == 240 and vertex_module.used_control_flow_fallback) {
                    std.debug.print("[vulkan dcb] traced vertex program 0x{x} uses linear control-flow fallback\n", .{vertex_address});
                }
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] using guest VS + guest PS; sampled={d} idx={any} storage={d}\n",
                    .{
                        graphics_resources.mapping_count,
                        draw.index_count,
                        vertex_storage.mapping_count,
                    },
                );
                try self.drawGraphicsShaders(
                    vertex_module.words,
                    fragment_words,
                    vertex_scalar_regs[0..vertex_scalar_count],
                    fragment_scalar_regs[0..fragment_scalar_count],
                    pipeline_state,
                    target,
                    depth_plane,
                    render_state.depth_control.clear_enabled,
                    graphics_resources.mapping_count != 0 or
                        vertex_storage.mapping_count != 0 or
                        fragment_storage.mapping_count != 0,
                    false,
                    draw,
                );
                if (self.flip_callbacks == 240) {
                    if (self.latest_render_target_index) |target_index| {
                        try self.materializeRenderTarget(target_index);
                        const captured_target = self.render_targets.items[target_index].target;
                        std.debug.print(
                            "[vulkan dcb] traced draw target @0x{x} {d}x{d} bpp={d} draw={d}\n",
                            .{
                                captured_target.descriptor.address,
                                captured_target.descriptor.width,
                                captured_target.descriptor.height,
                                captured_target.format.bytes_per_texel,
                                self.frame_profile.draws,
                            },
                        );
                        for (self.completed_frames.items) |captured| {
                            if (captured.guest_address != captured_target.descriptor.address) continue;
                            var trace_path_buffer: [96]u8 = undefined;
                            const trace_path = std.fmt.bufPrintZ(
                                &trace_path_buffer,
                                "out\\trace-frame-{d:0>4}-draw-{d}.ppm",
                                .{ self.flip_callbacks + 1, self.frame_profile.draws },
                            ) catch break;
                            if (captured_target.format.bytes_per_texel == 4) {
                                dumpFramePpm(
                                    trace_path.ptr,
                                    captured.width,
                                    captured.height,
                                    captured.pixels.items,
                                );
                            } else if (captured_target.format.bytes_per_texel == 8) {
                                dumpRgba16FloatFramePpm(
                                    trace_path.ptr,
                                    captured.width,
                                    captured.height,
                                    captured.pixels.items,
                                );
                            }
                            break;
                        }
                    }
                }
                // The persistent attachment is intentionally not read back
                // here.  A probe-VS retry used to require a full-frame GPU→CPU
                // round trip after every draw and also painted over valid
                // multi-pass output.  Geometry diagnostics now happen at flip.
                return;
            } else |err| {
                if (self.shouldReportShaderFailure(vertex_address, vertex_stage, err)) {
                    std.debug.print(
                        "[vulkan dcb] vertex program 0x{x} ({s}): translate={s}; falling back to probe VS\n",
                        .{ vertex_address, @tagName(vertex_stage), @errorName(err) },
                    );
                    std.debug.print(
                        "[vulkan dcb] vertex recovery stop={s}@0x{x} loads={d} known={d} storage={d}\n",
                        .{
                            @tagName(vertex_scalar.stop_reason),
                            vertex_scalar.stop_pc,
                            vertex_scalar.load_count,
                            vertex_scalar_count,
                            vertex_storage.mapping_count,
                        },
                    );
                    dumpScalarRegisters(vertex_scalar_regs[0..vertex_scalar_count]);
                    for (vertex_storage.mappings[0..vertex_storage.mapping_count]) |mapping| {
                        std.debug.print(
                            "  storage pc={any} V#s{d} slot={d} stride={d} soffset={any}\n",
                            .{
                                mapping.instruction_pc,
                                mapping.resource_sgpr,
                                mapping.descriptor_index,
                                mapping.stride,
                                mapping.soffset_value,
                            },
                        );
                    }
                    dumpShaderHead(vertex_analysis, vertex_analysis.program.instructions.items.len);
                }
            }
        } else {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] using probe VS + guest PS (no attr V# s4); storage_maps={d} sampled={d}\n",
                .{ vertex_storage.mapping_count, graphics_resources.mapping_count },
            );
        }
        if (probe_parameter_mask != 0) {
            // Decoded FFmpeg rows already use top-to-bottom image order. Keep
            // the NV12 conversion pass unflipped, then compensate exactly once
            // when the converted texture is composed through our negative-
            // height guest viewport.
            var probe_vertex_module = try buildFullscreenProbeVertexSpirv(
                self.allocator,
                !planar_video_pass,
            );
            defer probe_vertex_module.deinit(self.allocator);
            try self.drawGraphicsShaders(
                probe_vertex_module.words,
                fragment_words,
                &.{},
                fragment_scalar_regs[0..fragment_scalar_count],
                pipeline_state,
                target,
                depth_plane,
                render_state.depth_control.clear_enabled,
                graphics_resources.mapping_count != 0 or fragment_storage.mapping_count != 0,
                false,
                .{ .vertex_count = 3, .instance_count = 1 },
            );
            if (planar_video_pass and self.capture_first_graphics_frame and
                !self.captured_planar_video_pass)
            {
                self.captured_planar_video_pass = true;
                if (self.latest_render_target_index) |target_index| {
                    try self.materializeRenderTarget(target_index);
                    const captured_target = self.render_targets.items[target_index].target;
                    for (self.completed_frames.items) |captured| {
                        if (captured.guest_address != captured_target.descriptor.address) continue;
                        if (captured_target.format.bytes_per_texel == 4) {
                            dumpFramePpm(
                                "out\\first-video-pass.ppm",
                                captured.width,
                                captured.height,
                                captured.pixels.items,
                            );
                        } else if (captured_target.format.bytes_per_texel == 8) {
                            dumpRgba16FloatFramePpm(
                                "out\\first-video-pass.ppm",
                                captured.width,
                                captured.height,
                                captured.pixels.items,
                            );
                        }
                        std.debug.print(
                            "[vulkan dcb] dumped out\\first-video-pass.ppm target=0x{x}\n",
                            .{captured_target.descriptor.address},
                        );
                        break;
                    }
                }
            }
            return;
        }
        try self.drawGraphicsShaders(
            &graphics_probe_vertex_spirv,
            fragment_words,
            &.{},
            fragment_scalar_regs[0..fragment_scalar_count],
            pipeline_state,
            target,
            depth_plane,
            render_state.depth_control.clear_enabled,
            graphics_resources.mapping_count != 0 or fragment_storage.mapping_count != 0,
            false,
            .{ .vertex_count = 3, .instance_count = 1 },
        );
    }

    /// Convert the linear NV12 surfaces returned by AvPlayer directly into
    /// the resident RGBA color target. Unity normally performs this with a
    /// four-vertex NGG pass. Keeping the conversion independent of that
    /// partially implemented vertex ABI gives video frames their exact visible
    /// size while preserving the padded decoder pitch.
    fn emulatePlanarVideoPass(
        self: *Renderer,
        memory: GuestMemory,
        target: GuestColorTarget,
        luma: gpu.ImageDescriptor,
        chroma: gpu.ImageDescriptor,
    ) anyerror!void {
        if (target.format.vulkan != vk.format_r8g8b8a8_unorm or
            target.format.bytes_per_texel != 4 or luma.unified_format != 1 or
            chroma.unified_format != 14 or !luma.tile_mode.isLinear() or
            !chroma.tile_mode.isLinear())
        {
            return Error.UnsupportedSampledImage;
        }
        const width: usize = target.descriptor.width;
        const height: usize = target.descriptor.height;
        const luma_pitch: usize = luma.pitch;
        const chroma_pitch = std.math.mul(usize, chroma.pitch, 2) catch
            return Error.GuestBufferTooLarge;
        if (width == 0 or height == 0 or luma_pitch < width or
            chroma_pitch < width or chroma.height * 2 != height)
        {
            return Error.UnsupportedSampledImage;
        }
        const luma_bytes = std.math.mul(usize, luma_pitch, height) catch
            return Error.GuestBufferTooLarge;
        const chroma_bytes = std.math.mul(usize, chroma_pitch, chroma.height) catch
            return Error.GuestBufferTooLarge;
        const rgba_bytes = std.math.mul(usize, width, height) catch
            return Error.GuestBufferTooLarge;
        const frame_bytes = std.math.mul(usize, rgba_bytes, 4) catch
            return Error.GuestBufferTooLarge;
        if (luma_bytes > maximum_frame_bytes or chroma_bytes > maximum_frame_bytes or
            frame_bytes > maximum_frame_bytes)
        {
            return Error.GuestBufferTooLarge;
        }

        const y_plane = try self.allocator.alloc(u8, luma_bytes);
        defer self.allocator.free(y_plane);
        const uv_plane = try self.allocator.alloc(u8, chroma_bytes);
        defer self.allocator.free(uv_plane);
        const rgba = try self.allocator.alloc(u8, frame_bytes);
        defer self.allocator.free(rgba);
        if (!memory.read(memory.context, luma.address, y_plane) or
            !memory.read(memory.context, chroma.address, uv_plane))
        {
            return Error.GuestMemoryReadFailed;
        }

        for (0..height) |y| {
            const y_row = y * luma_pitch;
            const uv_row = (y / 2) * chroma_pitch;
            const rgba_row = y * width * 4;
            for (0..width) |x| {
                const c = @max(@as(i32, y_plane[y_row + x]) - 16, 0);
                const uv = uv_row + (x / 2) * 2;
                const u = @as(i32, uv_plane[uv]) - 128;
                const v = @as(i32, uv_plane[uv + 1]) - 128;
                const r = std.math.clamp((298 * c + 409 * v + 128) >> 8, 0, 255);
                const g = std.math.clamp((298 * c - 100 * u - 208 * v + 128) >> 8, 0, 255);
                const b = std.math.clamp((298 * c + 516 * u + 128) >> 8, 0, 255);
                const pixel = rgba_row + x * 4;
                rgba[pixel] = @intCast(r);
                rgba[pixel + 1] = @intCast(g);
                rgba[pixel + 2] = @intCast(b);
                rgba[pixel + 3] = 255;
            }
        }

        self.latest_video_render_target_index = try self.uploadLinearColorTarget(target, rgba);
    }

    /// Bypass Unity's identity sampled-image present pass. Its guest quad is
    /// indexed through the merged NGG ABI; until that ABI is complete, the
    /// translated vertices cover only a small central part of the display.
    /// The narrowly matched PS changes alpha only and copies RGB unchanged.
    fn emulateFullscreenSampleBlit(
        self: *Renderer,
        memory: GuestMemory,
        target: GuestColorTarget,
        source: gpu.ImageDescriptor,
    ) anyerror!bool {
        if ((target.format.vulkan != vk.format_r8g8b8a8_unorm and
            target.format.vulkan != vk.format_r8g8b8a8_srgb) or
            target.format.bytes_per_texel != 4 or source.unified_format != 56 or
            source.width != target.descriptor.width or
            source.height != target.descriptor.height or
            source.samplesLog2() != 0 or source.dcc_enabled or
            source.cmask_fast_clear or source.fmask_compression)
        {
            return false;
        }
        const layout = gpu.SurfaceLayout.fromImage(source) catch return false;
        const allocation_bytes = std.math.cast(usize, layout.required_source_bytes) orelse
            return Error.GuestBufferTooLarge;
        const frame_bytes = std.math.mul(
            usize,
            std.math.mul(usize, source.width, source.height) catch
                return Error.GuestBufferTooLarge,
            4,
        ) catch return Error.GuestBufferTooLarge;
        if (allocation_bytes == 0 or allocation_bytes > maximum_frame_bytes or
            frame_bytes > maximum_frame_bytes)
        {
            return Error.GuestBufferTooLarge;
        }
        try self.flushPendingGuestWrite(source.address, allocation_bytes);
        const allocation = try self.allocator.alloc(u8, allocation_bytes);
        defer self.allocator.free(allocation);
        const rgba = try self.allocator.alloc(u8, frame_bytes);
        defer self.allocator.free(rgba);
        if (!memory.read(memory.context, source.address, allocation)) {
            return Error.GuestMemoryReadFailed;
        }
        try layout.detile(allocation, rgba);
        const target_index = try self.uploadLinearColorTarget(target, rgba);
        if (self.isVideoSurface(source.address)) {
            self.markVideoSurface(target.descriptor.address);
            self.latest_video_render_target_index = target_index;
        }
        if (log_verbose_gpu or self.flip_callbacks < 24) {
            std.debug.print(
                "[vulkan dcb] emulated fullscreen sample blit: 0x{x} -> 0x{x} {d}x{d}\n",
                .{ source.address, target.descriptor.address, source.width, source.height },
            );
        }
        return true;
    }

    fn uploadLinearColorTarget(
        self: *Renderer,
        target: GuestColorTarget,
        rgba: []const u8,
    ) anyerror!usize {
        const frame_bytes = try colorTargetFrameBytes(target);
        if (rgba.len != frame_bytes) return Error.UnsupportedGraphicsState;
        const target_index = try self.acquireRenderTarget(target);
        const snapshot = self.render_targets.items[target_index];
        const upload = try self.createBuffer(
            frame_bytes,
            vk.buffer_usage_transfer_src_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(upload);
        try self.writeMapped(upload, rgba);

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const source_stage: vk.Flags = if (!snapshot.initialized)
            vk.pipeline_stage_top_of_pipe_bit
        else if (snapshot.shader_read_layout)
            vk.pipeline_stage_fragment_shader_bit | vk.pipeline_stage_compute_shader_bit
        else
            vk.pipeline_stage_color_attachment_output_bit;
        const to_transfer = vk.ImageMemoryBarrier{
            .source_access_mask = if (!snapshot.initialized)
                0
            else if (snapshot.shader_read_layout)
                vk.access_shader_read_bit
            else
                vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_transfer_write_bit,
            .old_layout = if (!snapshot.initialized)
                vk.image_layout_undefined
            else if (snapshot.shader_read_layout)
                vk.image_layout_shader_read_only_optimal
            else
                vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_transfer_dst_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            source_stage,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_transfer),
        );
        const copy = vk.BufferImageCopy{
            .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .image_extent = .{
                .width = target.descriptor.width,
                .height = target.descriptor.height,
                .depth = 1,
            },
        };
        self.device_functions.cmd_copy_buffer_to_image(
            command_buffer,
            upload.handle,
            snapshot.image.handle,
            vk.image_layout_transfer_dst_optimal,
            1,
            @ptrCast(&copy),
        );
        const to_attachment = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_color_attachment_optimal,
            .image = snapshot.image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_color_attachment_output_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&to_attachment),
        );
        try self.submitOneShot(command_buffer);

        self.frame_profile.upload_bytes +%= frame_bytes;
        self.frame_profile.texture_upload_bytes +%= frame_bytes;
        self.render_target_sequence +%= 1;
        const cached = &self.render_targets.items[target_index];
        cached.initialized = true;
        cached.shader_read_layout = false;
        cached.gpu_generation +%= 1;
        cached.last_used_sequence = self.render_target_sequence;
        self.latest_render_target_index = target_index;
        for (self.completed_frames.items) |*frame| {
            if (frame.guest_address == target.descriptor.address) frame.needs_writeback = false;
        }
        return target_index;
    }

    fn isVideoSurface(self: *const Renderer, address: u64) bool {
        for (self.video_surface_addresses[0..self.video_surface_count]) |candidate| {
            if (candidate == address) return true;
        }
        return false;
    }

    fn markVideoSurface(self: *Renderer, address: u64) void {
        if (address == 0 or self.isVideoSurface(address)) return;
        if (self.video_surface_count < self.video_surface_addresses.len) {
            self.video_surface_addresses[self.video_surface_count] = address;
            self.video_surface_count += 1;
            return;
        }
        std.mem.copyForwards(
            u64,
            self.video_surface_addresses[0 .. self.video_surface_addresses.len - 1],
            self.video_surface_addresses[1..],
        );
        self.video_surface_addresses[self.video_surface_addresses.len - 1] = address;
    }

    fn prepareGraphicsResources(
        self: *Renderer,
        bindings: *const gpu.ShaderBindings,
        reader: gpu.ShaderMemoryReader,
        analysis: *const gpu.ShaderAnalysis,
    ) anyerror!GraphicsResources {
        var result = GraphicsResources{};
        errdefer result.deinit(self);
        for (analysis.program.instructions.items) |inst| {
            if (inst.opcode != .image_sample) continue;
            if (inst.src1.kind != .sgpr or inst.src2.kind != .sgpr) {
                if (log_verbose_gpu) std.debug.print(
                    "[vulkan dcb] image_sample resource kinds t#={s} s#={s}\n",
                    .{ @tagName(inst.src1.kind), @tagName(inst.src2.kind) },
                );
                return Error.UnsupportedSampledImage;
            }
            var existing = false;
            for (result.mappings[0..result.mapping_count]) |mapping| {
                if (mapping.resource_sgpr == inst.src1.reg and mapping.sampler_sgpr == inst.src2.reg) {
                    existing = true;
                    break;
                }
            }
            if (existing) continue;
            if (result.mapping_count >= maximum_storage_descriptors) return Error.UnsupportedSampledImage;
            // T# and S# declarations have independent slot spaces. A shader
            // commonly samples the Y and UV video planes through one shared
            // sampler; advancing both slots per T#/S# pair incorrectly asks
            // for sampler 1 even though both instructions name sampler 0.
            const image_slot = graphicsSrtImageSlot(
                result.mappings[0..result.mapping_count],
                inst.src1.reg,
            );
            const sampler_slot = graphicsSrtSamplerSlot(
                result.mappings[0..result.mapping_count],
                inst.src2.reg,
            );
            // Graphics programs load T#/S# through scalar prologs just like
            // compute programs. Recover the state at this particular sample;
            // the fallback slots still cover shaders that reference only SRT
            // metadata and have no executable scalar producer.
            const sampled_scalar = gpu.scalar_provenance.evaluateResourceStateUntil(
                reader,
                bindings,
                inst.pc,
            );
            const image_descriptor = (try resolveComputeSampledImageDescriptor(
                bindings,
                reader,
                analysis,
                &sampled_scalar,
                inst.src1.reg,
                inst.pc,
                image_slot,
            )) orelse {
                std.debug.print(
                    "[vulkan dcb] sampled image missing for s{d} (user_data={d} srt={any})\n",
                    .{ inst.src1.reg, bindings.user_data_count, bindings.srt_address != null },
                );
                return Error.UnsupportedSampledImage;
            };
            const sampler_descriptor = (try resolveComputeSamplerDescriptor(
                bindings,
                reader,
                analysis,
                &sampled_scalar,
                inst.src2.reg,
                inst.pc,
                sampler_slot,
            )) orelse {
                std.debug.print(
                    "[vulkan dcb] sampler missing for s{d}\n",
                    .{inst.src2.reg},
                );
                return Error.UnsupportedSampledImage;
            };
            const descriptor_index: u32 = @intCast(result.mapping_count);
            const image = self.stageSampledImage(image_descriptor, sampler_descriptor, descriptor_index) catch |err| {
                std.debug.print(
                    "[vulkan dcb] stageSampledImage failed: {s} addr=0x{x} {d}x{d}x{d} pitch={d} fmt={d} type={s} tile={s} levels={d}..{d} base_array={d} dst={any} sampler(clamp={d}/{d}/{d} unorm={any} minmag={d}/{d} mip={d} lod={d:.3}..{d:.3})\n",
                    .{
                        @errorName(err),
                        image_descriptor.address,
                        image_descriptor.width,
                        image_descriptor.height,
                        image_descriptor.depth_or_layers,
                        image_descriptor.pitch,
                        image_descriptor.unified_format,
                        @tagName(image_descriptor.image_type),
                        @tagName(image_descriptor.tile_mode),
                        image_descriptor.base_level,
                        image_descriptor.last_level,
                        image_descriptor.base_array,
                        image_descriptor.dst_select,
                        sampler_descriptor.clamp_x,
                        sampler_descriptor.clamp_y,
                        sampler_descriptor.clamp_z,
                        sampler_descriptor.unnormalized_coordinates,
                        sampler_descriptor.minification_filter,
                        sampler_descriptor.magnification_filter,
                        sampler_descriptor.mip_filter,
                        sampler_descriptor.minimum_lod,
                        sampler_descriptor.maximum_lod,
                    },
                );
                return err;
            };
            result.images[result.image_count] = image;
            result.descriptors[result.image_count] = image_descriptor;
            result.image_count += 1;
            result.mappings[result.mapping_count] = .{
                .resource_sgpr = inst.src1.reg,
                .sampler_sgpr = inst.src2.reg,
                .descriptor_index = descriptor_index,
                .dimension = if (image_descriptor.image_type == .color_3d) .three_d else .two_d,
            };
            result.mapping_count += 1;
        }
        return result;
    }

    fn createBuffer(self: *Renderer, size: vk.DeviceSize, usage: vk.Flags, properties: vk.Flags) Error!OwnedBuffer {
        const create_info = vk.BufferCreateInfo{ .size = size, .usage = usage };
        var handle: vk.Buffer = 0;
        if (self.device_functions.create_buffer(self.device, &create_info, null, &handle) != vk.success) {
            return Error.BufferCreationFailed;
        }
        errdefer self.device_functions.destroy_buffer(self.device, handle, null);

        var requirements: vk.MemoryRequirements = undefined;
        self.device_functions.get_buffer_memory_requirements(self.device, handle, &requirements);
        const memory_type_index = self.findMemoryType(requirements.memory_type_bits, properties) orelse {
            return Error.NoCompatibleMemoryType;
        };
        const allocation_info = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type_index,
        };
        var memory: vk.DeviceMemory = 0;
        if (self.device_functions.allocate_memory(self.device, &allocation_info, null, &memory) != vk.success) {
            return Error.MemoryAllocationFailed;
        }
        errdefer self.device_functions.free_memory(self.device, memory, null);
        if (self.device_functions.bind_buffer_memory(self.device, handle, memory, 0) != vk.success) {
            return Error.MemoryBindingFailed;
        }
        return .{ .handle = handle, .memory = memory, .size = size };
    }

    fn createImageWithExtent(
        self: *Renderer,
        width: u32,
        height: u32,
        depth: u32,
        image_type: u32,
        format: u32,
        usage: vk.Flags,
    ) Error!OwnedImage {
        const create_info = vk.ImageCreateInfo{
            .image_type = image_type,
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = depth },
            .usage = usage,
        };
        var handle: vk.Image = 0;
        if (self.device_functions.create_image(self.device, &create_info, null, &handle) != vk.success) {
            return Error.ImageCreationFailed;
        }
        errdefer self.device_functions.destroy_image(self.device, handle, null);
        var requirements: vk.MemoryRequirements = undefined;
        self.device_functions.get_image_memory_requirements(self.device, handle, &requirements);
        const memory_type_index = self.findMemoryType(requirements.memory_type_bits, vk.memory_property_device_local_bit) orelse {
            return Error.NoCompatibleMemoryType;
        };
        const allocation_info = vk.MemoryAllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type_index,
        };
        var memory: vk.DeviceMemory = 0;
        if (self.device_functions.allocate_memory(self.device, &allocation_info, null, &memory) != vk.success) {
            return Error.MemoryAllocationFailed;
        }
        errdefer self.device_functions.free_memory(self.device, memory, null);
        if (self.device_functions.bind_image_memory(self.device, handle, memory, 0) != vk.success) {
            return Error.MemoryBindingFailed;
        }
        return .{ .handle = handle, .memory = memory };
    }

    fn createImage(self: *Renderer, width: u32, height: u32, format: u32, usage: vk.Flags) Error!OwnedImage {
        return self.createImageWithExtent(width, height, 1, vk.image_type_2d, format, usage);
    }

    fn updateStorageDescriptor(self: *Renderer, descriptor_index: u32, buffer: OwnedBuffer) void {
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = buffer.handle,
            .offset = 0,
            .range = buffer.size,
        };
        const write = vk.WriteDescriptorSet{
            .destination_set = self.descriptor_set,
            .destination_binding = 0,
            .destination_array_element = descriptor_index,
            .descriptor_count = 1,
            .descriptor_type = vk.descriptor_type_storage_buffer,
            .buffer_info = @ptrCast(&buffer_info),
        };
        self.device_functions.update_descriptor_sets(self.device, 1, @ptrCast(&write), 0, null);
    }

    fn updateSampledImageDescriptor(
        self: *Renderer,
        descriptor_index: u32,
        view: vk.ImageView,
        sampler: vk.Sampler,
        is_3d: bool,
    ) void {
        const image_info = vk.DescriptorImageInfo{
            .sampler = sampler,
            .image_view = view,
            .image_layout = vk.image_layout_shader_read_only_optimal,
        };
        const write = vk.WriteDescriptorSet{
            .destination_set = self.descriptor_set,
            .destination_binding = if (is_3d) sampled_image_3d_descriptor_binding else 1,
            .destination_array_element = descriptor_index,
            .descriptor_count = 1,
            .descriptor_type = vk.descriptor_type_combined_image_sampler,
            .image_info = @ptrCast(&image_info),
            .buffer_info = null,
        };
        self.device_functions.update_descriptor_sets(self.device, 1, @ptrCast(&write), 0, null);
        self.active_descriptor_set = self.descriptor_set;
    }

    fn updateStorageImageDescriptor(self: *Renderer, descriptor_index: u32, view: vk.ImageView) void {
        const image_info = vk.DescriptorImageInfo{
            .sampler = 0,
            .image_view = view,
            .image_layout = vk.image_layout_general,
        };
        const write = vk.WriteDescriptorSet{
            .destination_set = self.descriptor_set,
            .destination_binding = 2 + descriptor_index,
            .destination_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = vk.descriptor_type_storage_image,
            .image_info = @ptrCast(&image_info),
        };
        self.device_functions.update_descriptor_sets(self.device, 1, @ptrCast(&write), 0, null);
        self.active_descriptor_set = self.descriptor_set;
    }

    fn stageStorageImage(
        self: *Renderer,
        descriptor: gpu.ImageDescriptor,
        descriptor_index: u32,
        writable: bool,
    ) anyerror!PreparedStorageImage {
        const is_3d = descriptor.image_type == .color_3d;
        if ((!is_3d and descriptor.image_type != .color_2d) or descriptor.samplesLog2() != 0 or
            descriptor.viewBaseLevel() != 0 or descriptor.viewMipLevels() != 1 or
            (!is_3d and descriptor.depth_or_layers != 1) or descriptor.dcc_enabled or
            descriptor.cmask_fast_clear or descriptor.fmask_compression)
        {
            return Error.UnsupportedStorageImage;
        }
        const format = storageImageFormat(descriptor.unified_format) orelse
            return Error.UnsupportedStorageImage;
        const texture = gpu.TextureLayout.fromImage(descriptor) catch return Error.UnsupportedStorageImage;
        const subresource = texture.subresource(0, 0, 1) catch return Error.UnsupportedStorageImage;
        const staging_bytes_u64 = subresource.stagingBytes() catch return Error.UnsupportedStorageImage;
        if (staging_bytes_u64 == 0 or staging_bytes_u64 > maximum_frame_bytes or
            texture.required_source_bytes == 0 or texture.required_source_bytes > maximum_frame_bytes or
            subresource.block.bytes_per_element != storageImageBytesPerTexel(descriptor.unified_format))
        {
            return Error.UnsupportedStorageImage;
        }
        const staging_bytes = std.math.cast(usize, staging_bytes_u64) orelse return Error.UnsupportedStorageImage;
        const allocation_bytes = std.math.cast(usize, texture.required_source_bytes) orelse
            return Error.UnsupportedStorageImage;
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        try self.flushPendingGuestWrite(descriptor.address, allocation_bytes);

        const allocation = try self.allocator.alloc(u8, allocation_bytes);
        defer self.allocator.free(allocation);
        if (!memory.read(memory.context, descriptor.address, allocation)) return Error.GuestMemoryReadFailed;
        const linear = try self.allocator.alloc(u8, staging_bytes);
        defer self.allocator.free(linear);
        try subresource.detile(allocation, linear);

        const transfer = try self.createBuffer(
            staging_bytes,
            vk.buffer_usage_transfer_src_bit | vk.buffer_usage_transfer_dst_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        errdefer self.destroyBuffer(transfer);
        try self.writeMapped(transfer, linear);
        const image = try self.createImageWithExtent(
            descriptor.width,
            descriptor.height,
            descriptor.depth_or_layers,
            if (is_3d) vk.image_type_3d else vk.image_type_2d,
            format.vulkan,
            vk.image_usage_transfer_src_bit | vk.image_usage_transfer_dst_bit | vk.image_usage_storage_bit,
        );
        errdefer self.destroyImage(image);
        const view_info = vk.ImageViewCreateInfo{
            .image = image.handle,
            .view_type = if (is_3d) vk.image_view_type_3d else vk.image_view_type_2d,
            .format = format.vulkan,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        var view: vk.ImageView = 0;
        if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
            return Error.ImageViewCreationFailed;
        }
        errdefer self.device_functions.destroy_image_view(self.device, view, null);

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const upload_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = 0,
            .destination_access_mask = vk.access_transfer_write_bit,
            .old_layout = vk.image_layout_undefined,
            .new_layout = vk.image_layout_transfer_dst_optimal,
            .image = image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_top_of_pipe_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&upload_barrier),
        );
        const copy = vk.BufferImageCopy{
            .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .image_extent = .{
                .width = descriptor.width,
                .height = descriptor.height,
                .depth = descriptor.depth_or_layers,
            },
        };
        self.device_functions.cmd_copy_buffer_to_image(
            command_buffer,
            transfer.handle,
            image.handle,
            vk.image_layout_transfer_dst_optimal,
            1,
            @ptrCast(&copy),
        );
        const shader_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_shader_read_bit | vk.access_shader_write_bit,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_general,
            .image = image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_compute_shader_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&shader_barrier),
        );
        try self.submitOneShot(command_buffer);
        self.updateStorageImageDescriptor(descriptor_index, view);
        self.frame_profile.upload_bytes +%= staging_bytes;
        self.frame_profile.texture_upload_bytes +%= staging_bytes;
        return .{
            .descriptor = descriptor,
            .subresource = subresource,
            .image = image,
            .view = view,
            .transfer = transfer,
            .allocation_bytes = allocation_bytes,
            .staging_bytes = staging_bytes,
            .writable = writable,
        };
    }

    fn commitStorageImages(self: *Renderer, memory: GuestMemory, resources: *const ComputeResources) anyerror!void {
        for (resources.storage_images[0..resources.storage_image_count]) |prepared| {
            if (!prepared.writable) continue;
            const command_buffer = try self.beginOneShot();
            defer self.releaseOneShot(command_buffer);
            const transfer_barrier = vk.ImageMemoryBarrier{
                .source_access_mask = vk.access_shader_write_bit,
                .destination_access_mask = vk.access_transfer_read_bit,
                .old_layout = vk.image_layout_general,
                .new_layout = vk.image_layout_transfer_src_optimal,
                .image = prepared.image.handle,
                .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
            };
            self.device_functions.cmd_pipeline_barrier(
                command_buffer,
                vk.pipeline_stage_compute_shader_bit,
                vk.pipeline_stage_transfer_bit,
                0,
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&transfer_barrier),
            );
            const copy = vk.BufferImageCopy{
                .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
                .image_extent = .{
                    .width = prepared.descriptor.width,
                    .height = prepared.descriptor.height,
                    .depth = prepared.descriptor.depth_or_layers,
                },
            };
            self.device_functions.cmd_copy_image_to_buffer(
                command_buffer,
                prepared.image.handle,
                vk.image_layout_transfer_src_optimal,
                prepared.transfer.handle,
                1,
                @ptrCast(&copy),
            );
            try self.submitOneShot(command_buffer);

            const linear = try self.allocator.alloc(u8, prepared.staging_bytes);
            defer self.allocator.free(linear);
            try self.readMapped(prepared.transfer, linear);
            const allocation = try self.allocator.alloc(u8, prepared.allocation_bytes);
            defer self.allocator.free(allocation);
            if (!memory.read(memory.context, prepared.descriptor.address, allocation)) {
                return Error.GuestMemoryReadFailed;
            }
            try prepared.subresource.tile(linear, allocation);
            if (!memory.write(memory.context, prepared.descriptor.address, allocation)) {
                return Error.GuestMemoryWriteFailed;
            }
            self.frame_profile.readback_bytes +%= prepared.staging_bytes;
            self.frame_profile.storage_readback_bytes +%= prepared.staging_bytes;
        }
    }

    fn stageSampledImage(
        self: *Renderer,
        descriptor: gpu.resources.ImageDescriptor,
        sampler_descriptor: gpu.resources.SamplerDescriptor,
        descriptor_index: u32,
    ) anyerror!PreparedSampledImage {
        const image_format = sampledImageFormat(
            descriptor.unified_format,
            sampler_descriptor.force_srgb,
        ) orelse {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] unsupported sampled image format {d}\n",
                .{descriptor.unified_format},
            );
            return Error.UnsupportedSampledImage;
        };
        const bytes_per_texel = storageImageBytesPerTexel(descriptor.unified_format);
        const is_3d = descriptor.image_type == .color_3d;
        if (!is_3d and descriptor.image_type != .color_2d) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image type {s} (want color_2d/color_3d)\n",
                .{@tagName(descriptor.image_type)},
            );
            return Error.UnsupportedSampledImage;
        }
        // Compressed metadata is not decoded yet. In particular, it must never
        // be interpreted as color pixels: DCC/CMASK are control data, not an
        // alternate image payload.
        if (descriptor.metadata_address != 0) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image: ignoring metadata @0x{x}\n",
                .{descriptor.metadata_address},
            );
        }
        const layout = try SampledStagingLayout.fromImage(descriptor);
        const staging_bytes_u64 = try layout.stagingBytes();
        if ((!is_3d and layout.depthOrLayers() != 1) or
            layout.bytesPerElement() != bytes_per_texel or staging_bytes_u64 == 0 or
            staging_bytes_u64 > maximum_frame_bytes or layout.requiredSourceBytes() == 0 or
            layout.requiredSourceBytes() > maximum_frame_bytes)
        {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image layout rejected depth/layers={d} bpp={d} stage=0x{x} source=0x{x}\n",
                .{ layout.depthOrLayers(), layout.bytesPerElement(), staging_bytes_u64, layout.requiredSourceBytes() },
            );
            return Error.UnsupportedSampledImage;
        }
        if (!is_3d) {
            if (try self.stageResidentRenderTarget(
                descriptor,
                sampler_descriptor,
                image_format,
                descriptor_index,
            )) |resident| {
                return resident;
            }
        }
        const byte_count = std.math.cast(usize, staging_bytes_u64) orelse return Error.UnsupportedSampledImage;
        const probe_span = std.math.cast(usize, layout.requiredSourceBytes()) orelse 0;
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;

        // A rendered target sampled as a texture must see the rendered frame:
        // publish its deferred writeback before hashing or staging guest bytes,
        // otherwise the cache would bind stale contents.
        self.flushPendingGuestWrite(descriptor.address, probe_span) catch |err| {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image writeback flush failed: {s} addr=0x{x}\n",
                .{ @errorName(err), descriptor.address },
            );
            return err;
        };

        const state_hash = sampledImageStateHash(descriptor, sampler_descriptor);
        const source_generation = self.sampledSourceGeneration(descriptor.address);
        const content_hash = self.probeSampledSource(
            memory,
            descriptor.address,
            probe_span,
            source_generation,
        );

        var cache_hit_idx: ?usize = null;
        for (self.sampled_image_cache.items, 0..) |*item, idx| {
            if (item.guest_address == descriptor.address and
                item.width == descriptor.width and
                item.height == descriptor.height and
                item.depth == descriptor.depth_or_layers and
                item.image_type == @intFromEnum(descriptor.image_type) and
                item.tile_mode == @intFromEnum(descriptor.tile_mode) and
                item.state_hash == state_hash and
                item.source_generation == source_generation and
                item.content_hash == content_hash)
            {
                cache_hit_idx = idx;
                break;
            }
        }

        if (cache_hit_idx) |idx| {
            var item = &self.sampled_image_cache.items[idx];
            item.last_used_frame = self.frame_sequence;
            self.texture_cache_hits += 1;
            if (self.texture_cache_hits == 1) {
                std.debug.print("[vulkan dcb] texture cache hit: first time! addr=0x{x} hash={x}\n", .{ descriptor.address, content_hash });
            }
            self.updateSampledImageDescriptor(descriptor_index, item.view, item.sampler, descriptor.image_type == .color_3d);
            return .{ .image = item.image, .view = item.view, .sampler = item.sampler };
        }
        self.texture_cache_misses += 1;
        if (self.texture_cache_misses == 1) {
            std.debug.print("[vulkan dcb] texture cache miss: first @0x{x} hash={x}\n", .{ descriptor.address, content_hash });
        }
        if (byte_count >= 16 * 1024 * 1024) {
            std.debug.print(
                "[vulkan dcb] large texture upload #{d}: @0x{x} {d}x{d} bytes={d} generation={d} hash={x}\n",
                .{ self.texture_cache_misses, descriptor.address, descriptor.width, descriptor.height, byte_count, source_generation, content_hash },
            );
        }

        const linear = try self.allocator.alloc(u8, byte_count);
        defer self.allocator.free(linear);
        const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
        if (layout.isLinear()) {
            try layout.stage(reader, descriptor.address, linear);
        } else {
            // Layout.stage performs one checked guest-memory callback per
            // texel. A 4096×4096 RGBA texture therefore issued 16.7 million
            // range checks and took several seconds. Validate/copy the tiled
            // allocation once, then detile the host slice without callbacks.
            const tiled = try self.allocator.alloc(u8, probe_span);
            defer self.allocator.free(tiled);
            if (!memory.read(memory.context, descriptor.address, tiled)) return Error.GuestMemoryReadFailed;
            try layout.detile(tiled, linear);
        }
        // Counting every non-zero texel is useful only in verbose diagnostics;
        // doing it unconditionally added another full 64 MiB CPU pass for a
        // 4096² texture after detiling. Normal rendering only needs to know
        // whether the image is entirely empty.
        const nonzero = if (log_verbose_gpu)
            countNonzeroRgba(linear)
        else if (containsNonzeroByte(linear))
            @as(u32, 1)
        else
            @as(u32, 0);
        const metadata = gpu.MetadataSurface.fromImage(descriptor);
        if (nonzero == 0 and metadata.hasAny()) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] compressed/metadata-only sample left transparent addr=0x{x} meta=0x{x} dcc=0x{x} cmask=0x{x} fmask=0x{x}\n",
                .{ descriptor.address, metadata.metadata_address, metadata.dcc_address, metadata.cmask_address, metadata.fmask_address },
            );
        }
        // Probe several points in the guest surface: tiled data may put the
        // first texels far from the base while the head of the allocation is
        // still zero (clear/padding).
        const raw_probe_span = std.math.cast(usize, layout.requiredSourceBytes()) orelse 0;
        var raw_nonzero: u32 = 0;
        var raw_probe_hits: u32 = 0;
        if (raw_probe_span != 0) {
            const steps = [_]u64{ 0, raw_probe_span / 4, raw_probe_span / 2, (raw_probe_span * 3) / 4 };
            var step_i: usize = 0;
            while (step_i < steps.len) : (step_i += 1) {
                var chunk: [64]u8 = @splat(0);
                const at = descriptor.address + steps[step_i];
                const want = @min(chunk.len, raw_probe_span -% @as(usize, @intCast(@min(steps[step_i], raw_probe_span))));
                if (want == 0) continue;
                if (!memory.read(memory.context, at, chunk[0..want])) continue;
                var nz: u32 = 0;
                for (chunk[0..want]) |b| {
                    if (b != 0) nz += 1;
                }
                if (nz != 0) {
                    raw_nonzero += nz;
                    raw_probe_hits += 1;
                }
            }
        }
        if (log_verbose_gpu or self.texture_cache_misses <= 4) std.debug.print(
            "[vulkan dcb] staged sample {d}x{d}x{d} tile={s} addr=0x{x} nonzero_texels={d}/{d} raw_probe_nz={d} hits={d} first_rgba=({d},{d},{d},{d})\n",
            .{
                descriptor.width,
                descriptor.height,
                descriptor.depth_or_layers,
                @tagName(descriptor.tile_mode),
                descriptor.address,
                nonzero,
                if (byte_count >= @as(usize, bytes_per_texel))
                    byte_count / @as(usize, bytes_per_texel)
                else
                    0,
                raw_nonzero,
                raw_probe_hits,
                if (linear.len > 0) linear[0] else 0,
                if (linear.len > 1) linear[1] else 0,
                if (linear.len > 2) linear[2] else 0,
                if (linear.len > 3) linear[3] else 0,
            },
        );
        // Deep raw probe: 64-byte samples across a wider window (title may
        // place the true surface a few tiles past the T# base, or leave the
        // head cleared while the body is valid).
        var first_hit_off: ?u64 = null;
        if (raw_nonzero == 0 and descriptor.width != 0 and descriptor.height != 0) {
            const deep_span: u64 = @max(
                raw_probe_span,
                @as(u64, descriptor.width) * descriptor.height * descriptor.depth_or_layers * @as(u64, bytes_per_texel) * 2,
            );
            const deep_cap: u64 = 8 * 1024 * 1024;
            const span = @min(deep_span, deep_cap);
            var step: u64 = 0;
            const stride: u64 = 4096;
            while (step < span) : (step += stride) {
                var chunk: [64]u8 = @splat(0);
                if (!memory.read(memory.context, descriptor.address + step, &chunk)) break;
                var nz: u32 = 0;
                for (chunk) |b| {
                    if (b != 0) nz += 1;
                }
                if (nz != 0) {
                    raw_nonzero += nz;
                    raw_probe_hits += 1;
                    if (first_hit_off == null) first_hit_off = step;
                    if (raw_probe_hits <= 3) {
                        if (log_verbose_gpu) std.debug.print(
                            "[vulkan dcb] raw hit @+0x{x} nz={d} head={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
                            .{ step, nz, chunk[0], chunk[1], chunk[2], chunk[3] },
                        );
                    }
                }
            }
        }
        // Keep the first-pass decode strict: if the surface is empty or the
        // staged bytes contain no non-zero RGBA payload, avoid guessing an
        // unrelated linear region from guest memory. That fallback path is what
        // turns a bad tiled/DCC decode into a striped or "borrowed" texture.
        if (nonzero == 0 and descriptor.width != 0 and descriptor.height != 0) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sample empty @0x{x} {d}x{d} tile={s} meta=0x{x} — no fallback decode\n",
                .{
                    descriptor.address,
                    descriptor.width,
                    descriptor.height,
                    @tagName(descriptor.tile_mode),
                    descriptor.metadata_address,
                },
            );
            @memset(linear, 0);
        }
        const components = try sampledImageComponents(descriptor.dst_select);
        const upload = try self.createBuffer(
            byte_count,
            vk.buffer_usage_transfer_src_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(upload);
        try self.writeMapped(upload, linear);
        const image = try self.createImageWithExtent(
            descriptor.width,
            descriptor.height,
            if (is_3d) descriptor.depth_or_layers else 1,
            if (is_3d) vk.image_type_3d else vk.image_type_2d,
            image_format,
            vk.image_usage_transfer_dst_bit | vk.image_usage_sampled_bit,
        );
        errdefer self.destroyImage(image);

        const command_buffer = try self.beginOneShot();
        defer self.releaseOneShot(command_buffer);
        const upload_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = 0,
            .destination_access_mask = vk.access_transfer_write_bit,
            .old_layout = vk.image_layout_undefined,
            .new_layout = vk.image_layout_transfer_dst_optimal,
            .image = image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_top_of_pipe_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&upload_barrier),
        );
        const copy = vk.BufferImageCopy{
            .image_subresource = .{ .aspect_mask = vk.image_aspect_color_bit },
            .image_extent = .{
                .width = descriptor.width,
                .height = descriptor.height,
                .depth = if (is_3d) descriptor.depth_or_layers else 1,
            },
        };
        self.device_functions.cmd_copy_buffer_to_image(
            command_buffer,
            upload.handle,
            image.handle,
            vk.image_layout_transfer_dst_optimal,
            1,
            @ptrCast(&copy),
        );
        const shader_barrier = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_shader_read_bit,
            .old_layout = vk.image_layout_transfer_dst_optimal,
            .new_layout = vk.image_layout_shader_read_only_optimal,
            .image = image.handle,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_fragment_shader_bit | vk.pipeline_stage_compute_shader_bit,
            0,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&shader_barrier),
        );
        try self.submitOneShot(command_buffer);
        self.frame_profile.upload_bytes +%= byte_count;
        self.frame_profile.texture_upload_bytes +%= byte_count;

        const view_info = vk.ImageViewCreateInfo{
            .image = image.handle,
            .view_type = if (is_3d) vk.image_view_type_3d else vk.image_view_type_2d,
            .format = image_format,
            .components = components,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        var view: vk.ImageView = 0;
        if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
            return Error.ImageViewCreationFailed;
        }
        errdefer self.device_functions.destroy_image_view(self.device, view, null);
        const sampler = try self.createGuestSampler(sampler_descriptor);
        errdefer self.device_functions.destroy_sampler(self.device, sampler, null);
        self.updateSampledImageDescriptor(descriptor_index, view, sampler, descriptor.image_type == .color_3d);
        self.sampled_image_uploads += 1;

        // A streamed/video texture keeps one allocation per guest surface, not
        // one allocation per content hash. All earlier draws are complete at
        // this synchronous upload point, so the superseded image is no longer
        // in flight and can be retired safely.
        var stale_index = self.sampled_image_cache.items.len;
        while (stale_index > 0) {
            stale_index -= 1;
            const stale = self.sampled_image_cache.items[stale_index];
            if (stale.guest_address != descriptor.address or
                stale.width != descriptor.width or
                stale.height != descriptor.height or
                stale.depth != descriptor.depth_or_layers or
                stale.image_type != @intFromEnum(descriptor.image_type) or
                stale.tile_mode != @intFromEnum(descriptor.tile_mode) or
                stale.state_hash != state_hash)
            {
                continue;
            }
            self.device_functions.destroy_image_view(self.device, stale.view, null);
            self.device_functions.destroy_sampler(self.device, stale.sampler, null);
            self.destroyImage(stale.image);
            _ = self.sampled_image_cache.orderedRemove(stale_index);
        }

        if (self.sampled_image_cache.items.len >= maximum_sampled_images) {
            var oldest_idx: usize = 0;
            var oldest_frame: u64 = std.math.maxInt(u64);
            for (self.sampled_image_cache.items, 0..) |item, idx| {
                if (item.last_used_frame < oldest_frame) {
                    oldest_frame = item.last_used_frame;
                    oldest_idx = idx;
                }
            }
            const evicted = self.sampled_image_cache.items[oldest_idx];
            self.device_functions.destroy_image_view(self.device, evicted.view, null);
            self.device_functions.destroy_sampler(self.device, evicted.sampler, null);
            self.destroyImage(evicted.image);
            _ = self.sampled_image_cache.orderedRemove(oldest_idx);
        }

        self.sampled_image_cache.append(self.allocator, .{
            .guest_address = descriptor.address,
            .width = descriptor.width,
            .height = descriptor.height,
            .depth = descriptor.depth_or_layers,
            .image_type = @intFromEnum(descriptor.image_type),
            .tile_mode = @intFromEnum(descriptor.tile_mode),
            .state_hash = state_hash,
            .source_generation = source_generation,
            .content_hash = content_hash,
            .image = image,
            .view = view,
            .sampler = sampler,
            .last_used_frame = self.frame_sequence,
        }) catch {};

        return .{ .image = image, .view = view, .sampler = sampler };
    }

    fn sampledSourceGeneration(self: *const Renderer, address: u64) u64 {
        for (self.render_targets.items) |cached| {
            if (cached.target.descriptor.address == address) return cached.gpu_generation;
        }
        for (self.completed_frames.items) |cached| {
            if (cached.guest_address == address) return cached.sequence;
        }
        return 0;
    }

    fn createGuestSampler(self: *Renderer, descriptor: gpu.resources.SamplerDescriptor) Error!vk.Sampler {
        const info = try guestSamplerCreateInfo(descriptor);
        var sampler: vk.Sampler = 0;
        if (self.device_functions.create_sampler(self.device, &info, null, &sampler) != vk.success) {
            return Error.SamplerCreationFailed;
        }
        return sampler;
    }

    fn beginOneShot(self: *Renderer) Error!vk.CommandBuffer {
        const command_buffer = self.one_shot_command_buffer orelse return Error.CommandBufferAllocationFailed;
        if (self.device_functions.reset_command_buffer(command_buffer, 0) != vk.success) {
            return Error.CommandBufferResetFailed;
        }
        const begin_info = vk.CommandBufferBeginInfo{ .flags = vk.command_buffer_usage_one_time_submit_bit };
        if (self.device_functions.begin_command_buffer(command_buffer, &begin_info) != vk.success) {
            return Error.CommandBufferBeginFailed;
        }
        return command_buffer;
    }

    fn releaseOneShot(self: *Renderer, command_buffer: vk.CommandBuffer) void {
        // The renderer-owned buffer is reset by the next begin. A few isolated
        // validation paths still allocate a private buffer and release it here.
        if (self.one_shot_command_buffer == command_buffer) return;
        self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
    }

    fn submitOneShot(self: *Renderer, command_buffer: vk.CommandBuffer) Error!void {
        if (self.device_functions.end_command_buffer(command_buffer) != vk.success) return Error.CommandBufferEndFailed;
        const fence = self.one_shot_fence;
        if (fence == 0) return Error.FenceCreationFailed;
        if (self.device_functions.reset_fences(self.device, 1, @ptrCast(&fence)) != vk.success) {
            return Error.FenceResetFailed;
        }
        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .command_buffers = @ptrCast(&command_buffer),
        };
        if (self.device_functions.queue_submit(self.queue, 1, @ptrCast(&submit_info), fence) != vk.success) {
            return Error.QueueSubmissionFailed;
        }
        self.frame_profile.submits += 1;
        const wait_started = hostTimestampNs();
        if (self.device_functions.wait_for_fences(self.device, 1, @ptrCast(&fence), vk.true_value, ~@as(u64, 0)) != vk.success) {
            return Error.FenceWaitFailed;
        }
        const wait_finished = hostTimestampNs();
        if (wait_finished >= wait_started) self.frame_profile.fence_wait_ns +%= wait_finished - wait_started;
    }

    fn destroyBuffer(self: *Renderer, buffer: OwnedBuffer) void {
        self.device_functions.destroy_buffer(self.device, buffer.handle, null);
        self.device_functions.free_memory(self.device, buffer.memory, null);
    }

    fn destroyImage(self: *Renderer, image: OwnedImage) void {
        self.device_functions.destroy_image(self.device, image.handle, null);
        self.device_functions.free_memory(self.device, image.memory, null);
    }

    fn findMemoryType(self: *const Renderer, supported_bits: u32, required: vk.Flags) ?u32 {
        return findMemoryTypeIn(self.memory_properties, supported_bits, required);
    }

    fn writeMapped(self: *Renderer, buffer: OwnedBuffer, bytes: []const u8) Error!void {
        var mapped: ?*anyopaque = null;
        if (self.device_functions.map_memory(self.device, buffer.memory, 0, bytes.len, 0, &mapped) != vk.success) {
            return Error.MemoryMapFailed;
        }
        defer self.device_functions.unmap_memory(self.device, buffer.memory);
        const destination: [*]u8 = @ptrCast(mapped orelse return Error.MemoryMapFailed);
        @memcpy(destination[0..bytes.len], bytes);
    }

    fn writeGraphicsScalarValues(
        self: *Renderer,
        vertex: []const gpu.ShaderSpirvScalarRegister,
        fragment: []const gpu.ShaderSpirvScalarRegister,
    ) Error!void {
        if (vertex.len > dynamic_scalar_words_per_stage or
            fragment.len > dynamic_scalar_words_per_stage)
        {
            return Error.InvalidStorageDescriptor;
        }
        const words = self.dynamic_scalar_mapping orelse return Error.InvalidStorageDescriptor;
        for (vertex, 0..) |scalar, index| words[index] = scalar.value;
        for (fragment, 0..) |scalar, index| words[dynamic_scalar_words_per_stage + index] = scalar.value;
    }

    fn expectMapped(self: *Renderer, buffer: OwnedBuffer, expected: []const u8) Error!void {
        var mapped: ?*anyopaque = null;
        if (self.device_functions.map_memory(self.device, buffer.memory, 0, expected.len, 0, &mapped) != vk.success) {
            return Error.MemoryMapFailed;
        }
        defer self.device_functions.unmap_memory(self.device, buffer.memory);
        const actual: [*]const u8 = @ptrCast(mapped orelse return Error.MemoryMapFailed);
        if (!std.mem.eql(u8, actual[0..expected.len], expected)) return Error.ReadbackMismatch;
    }

    fn readMapped(self: *Renderer, buffer: OwnedBuffer, destination: []u8) Error!void {
        var mapped: ?*anyopaque = null;
        if (self.device_functions.map_memory(self.device, buffer.memory, 0, destination.len, 0, &mapped) != vk.success) {
            return Error.MemoryMapFailed;
        }
        defer self.device_functions.unmap_memory(self.device, buffer.memory);
        const source: [*]const u8 = @ptrCast(mapped orelse return Error.MemoryMapFailed);
        @memcpy(destination, source[0..destination.len]);
    }

    fn createSmokeShader(self: *Renderer) Error!vk.ShaderModule {
        return self.createShader(&smoke_compute_spirv);
    }

    fn createShader(self: *Renderer, words: []const u32) Error!vk.ShaderModule {
        const create_info = vk.ShaderModuleCreateInfo{
            .code_size = words.len * @sizeOf(u32),
            .code = words.ptr,
        };
        var shader: vk.ShaderModule = 0;
        if (self.device_functions.create_shader_module(self.device, &create_info, null, &shader) != vk.success) {
            return Error.ShaderModuleCreationFailed;
        }
        return shader;
    }

    const dcb_vtable = gpu.DcbBackend.VTable{
        .read = dcbRead,
        .write = dcbWrite,
        .acquire = dcbAcquire,
        .release = dcbRelease,
        .wait = dcbWait,
        .write_data = dcbWriteData,
        .dma_data = dcbDmaData,
        .event = dcbEvent,
        .flip = dcbFlip,
        .draw = dcbDraw,
        .dispatch = dcbDispatch,
    };

    fn fromContext(context: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(context.?));
    }

    fn dcbRead(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self = fromContext(context);
        self.flushGuestStorageRange(address, bytes.len) catch return false;
        _ = self.materializeHtileTargetAt(address, bytes.len) catch return false;
        const memory = self.guest_memory orelse return false;
        return memory.read(memory.context, address, bytes);
    }

    fn prepareCmaskWrite(self: *Renderer, address: u64, size: usize) anyerror!void {
        if (size == 0) return;
        var index: usize = 0;
        while (index < self.render_targets.items.len) : (index += 1) {
            const snapshot = self.render_targets.items[index];
            const descriptor = snapshot.target.descriptor;
            if (!descriptor.cmask_fast_clear or descriptor.cmask_address == 0 or descriptor.dcc_enabled) continue;
            const layout = gpu.CmaskLayout.fromColorTarget(descriptor) catch continue;
            if (!byteRangesOverlap(address, size, descriptor.cmask_address, layout.required_bytes)) continue;

            // Preserve any resident rendering before the guest changes the
            // metadata which defines how the base allocation is interpreted.
            if (snapshot.initialized) {
                const visible_bytes = try colorTargetFrameBytes(snapshot.target);
                try self.flushPendingGuestWrite(descriptor.address, visible_bytes);
            }
            self.render_targets.items[index].initialized = false;
        }
    }

    fn prepareHtileWrite(self: *Renderer, address: u64, size: usize) void {
        if (size == 0) return;
        for (self.htile_targets.items) |*cached| {
            if (!cached.target.htile_enabled or cached.target.htile_address == 0) continue;
            const layout = gpu.HtileLayout.fromDepthTarget(cached.target) catch continue;
            if (!byteRangesOverlap(address, size, cached.target.htile_address, layout.required_bytes)) continue;
            cached.resolved = false;
        }
    }

    fn dcbWrite(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = fromContext(context);
        self.flushGuestStorageRange(address, bytes.len) catch return false;
        self.prepareCmaskWrite(address, bytes.len) catch return false;
        self.prepareHtileWrite(address, bytes.len);
        const memory = self.guest_memory orelse return false;
        return memory.write(memory.context, address, bytes);
    }

    fn dcbAcquire(context: ?*anyopaque, _: gpu.state.AcquireMem) bool {
        const self = fromContext(context);
        self.acquire_callbacks += 1;
        self.last_sync_error = null;
        return true;
    }

    fn dcbRelease(context: ?*anyopaque, release: gpu.state.ReleaseMem) bool {
        const self = fromContext(context);
        self.release_callbacks += 1;
        // The synchronous queue has completed, but a release normally exposes
        // only its fence/timestamp payload to the CPU. Keep color attachments
        // and large compute outputs resident; exact texture/presentation reads
        // materialize the resource they name instead of every dirty target.
        if ((release.destination != 0 and release.destination != 1) or release.address == 0) return true;
        var bytes: [8]u8 = undefined;
        const accepted = switch (release.data_selection) {
            0 => true,
            1 => blk: {
                std.mem.writeInt(u32, bytes[0..4], @truncate(release.data), .little);
                break :blk dcbWrite(context, release.address, bytes[0..4]);
            },
            2 => blk: {
                std.mem.writeInt(u64, &bytes, release.data, .little);
                break :blk dcbWrite(context, release.address, &bytes);
            },
            3, 4 => blk: {
                std.mem.writeInt(u64, &bytes, releaseTimestampCounter(), .little);
                break :blk dcbWrite(context, release.address, &bytes);
            },
            // GDS is not modelled yet. It is not the packet payload and must
            // not be written as one; accepting the ordered release preserves
            // queue progress until the GDS storage itself is implemented.
            5 => true,
            else => blk: {
                self.last_sync_error = Error.UnsupportedReleaseDataSelection;
                std.debug.print(
                    "[vulkan dcb] release rejected: unsupported data selection {d} (dst={d}, address=0x{x})\n",
                    .{ release.data_selection, release.destination, release.address },
                );
                break :blk false;
            },
        };
        if (!accepted and release.data_selection >= 1 and release.data_selection <= 4) {
            self.last_sync_error = Error.GuestMemoryWriteFailed;
            std.debug.print(
                "[vulkan dcb] release rejected: {s} (address=0x{x}, selection={d})\n",
                .{ @errorName(Error.GuestMemoryWriteFailed), release.address, release.data_selection },
            );
        }
        return accepted;
    }

    fn dcbWait(context: ?*anyopaque, _: gpu.state.WaitRegMem, _: bool) bool {
        const self = fromContext(context);
        self.wait_callbacks += 1;
        // The command processor has already performed the checked label read.
        // A false result blocks the DCB; accepting the callback preserves that
        // continuation rather than turning a normal wait into a backend error.
        self.last_sync_error = null;
        return true;
    }

    fn dcbWriteData(context: ?*anyopaque, info: gpu.state.WriteData, values: []const u32) bool {
        const self = fromContext(context);
        self.write_data_callbacks += 1;
        // WRITE_DATA publishes only the named destination. It does not require
        // unrelated resident images to round-trip through guest memory.
        if (info.destination != 1 and info.destination != 2 and
            info.destination != 4 and info.destination != 5)
        {
            return true;
        }
        var bytes: [4]u8 = undefined;
        for (values, 0..) |value, index| {
            std.mem.writeInt(u32, &bytes, value, .little);
            const address = info.address + if (info.increment_address) @as(u64, index) * 4 else 0;
            if (!dcbWrite(context, address, &bytes)) {
                self.last_sync_error = Error.GuestMemoryWriteFailed;
                std.debug.print(
                    "[vulkan dcb] write-data rejected: {s} (address=0x{x})\n",
                    .{ @errorName(Error.GuestMemoryWriteFailed), address },
                );
                return false;
            }
        }
        return true;
    }

    fn invalidateDmaDestination(self: *Renderer, address: u64, size: usize) void {
        for (self.render_targets.items) |*cached| {
            const frame_bytes = colorTargetFrameBytes(cached.target) catch continue;
            if (!byteRangesOverlap(address, size, cached.target.descriptor.address, frame_bytes)) continue;
            cached.initialized = false;
            cached.gpu_generation = 0;
            cached.host_generation = 0;
        }
        for (self.completed_frames.items) |*cached| {
            const target = cached.target orelse continue;
            const frame_bytes = colorTargetFrameBytes(target) catch continue;
            if (!byteRangesOverlap(address, size, cached.guest_address, frame_bytes)) continue;
            cached.needs_writeback = false;
            cached.guest_address = 0;
            cached.sequence = 0;
            cached.target = null;
        }
    }

    fn ensureGdsStorage(self: *Renderer) bool {
        if (self.gds_storage.items.len != 0) return true;
        self.gds_storage.resize(self.allocator, 64 * 1024) catch return false;
        @memset(self.gds_storage.items, 0);
        return true;
    }

    fn dcbDmaData(context: ?*anyopaque, dma: gpu.state.DmaData) bool {
        const self = fromContext(context);
        self.dma_data_callbacks += 1;
        if (self.dma_data_callbacks <= 16) {
            std.debug.print(
                "[vulkan dcb] DMA_DATA #{d} src={d}@0x{x} dst={d}@0x{x} bytes=0x{x}\n",
                .{
                    self.dma_data_callbacks,
                    dma.source,
                    dma.source_address,
                    dma.destination,
                    dma.destination_address,
                    dma.byte_count,
                },
            );
        }
        if (dma.byte_count == 0) return true;
        const byte_count: usize = dma.byte_count;
        const bytes = self.allocator.alloc(u8, byte_count) catch return false;
        defer self.allocator.free(bytes);
        const memory = self.guest_memory orelse return false;

        switch (dma.source) {
            0, 3 => {
                self.flushPendingGuestWrite(dma.source_address, byte_count) catch return false;
                if (!memory.read(memory.context, dma.source_address, bytes)) return false;
            },
            1 => {
                if (!self.ensureGdsStorage()) return false;
                const offset = std.math.cast(usize, dma.source_address) orelse return false;
                if (offset > self.gds_storage.items.len or byte_count > self.gds_storage.items.len - offset) return false;
                @memcpy(bytes, self.gds_storage.items[offset..][0..byte_count]);
            },
            2 => {
                const immediate: [4]u8 = @bitCast(@as(u32, @truncate(dma.source_address)));
                for (bytes, 0..) |*byte, index| byte.* = immediate[index & 3];
            },
            // Clock/counter selectors are synchronization aids, not bulk
            // image sources. Preserve queue progress until their counters are
            // modelled without inventing bytes.
            else => return true,
        }

        switch (dma.destination) {
            0, 3 => {
                // Unity emits four-byte immediate-to-L2 markers with a null
                // destination between workloads. They carry ordering bits but
                // intentionally publish no guest memory.
                if (dma.destination_address == 0) return true;
                self.flushPendingGuestWrite(dma.destination_address, byte_count) catch return false;
                self.prepareCmaskWrite(dma.destination_address, byte_count) catch return false;
                self.prepareHtileWrite(dma.destination_address, byte_count);
                if (!memory.write(memory.context, dma.destination_address, bytes)) return false;
                self.invalidateDmaDestination(dma.destination_address, byte_count);
            },
            1 => {
                if (!self.ensureGdsStorage()) return false;
                const offset = std.math.cast(usize, dma.destination_address) orelse return false;
                if (offset > self.gds_storage.items.len or byte_count > self.gds_storage.items.len - offset) return false;
                @memcpy(self.gds_storage.items[offset..][0..byte_count], bytes);
            },
            else => return true,
        }
        return true;
    }

    fn dcbEvent(context: ?*anyopaque, _: gpu.state.EventWrite) bool {
        const self = fromContext(context);
        self.event_callbacks += 1;
        // Queue work is already fence-completed. Resource consumers perform
        // address-specific materialization when they actually need host bytes.
        self.last_sync_error = null;
        return true;
    }

    /// Shows a display buffer straight out of guest memory.
    ///
    /// Used when a flip names a buffer this renderer never drew into. The bytes
    /// are the title's own: it may have cleared them, written them with the
    /// processor, or left them untouched. Showing them is what the console
    /// does, and it is closer to the truth than showing a colour of our
    /// choosing would be.
    fn presentGuestBuffer(self: *Renderer, buffer: DisplayBuffer, flip: gpu.state.Flip) bool {
        const sink = self.presentation_sink orelse return true;
        if (buffer.width == 0 or buffer.height == 0) return false;

        // The buffer may be one this renderer drew into and then evicted from
        // the host frame cache; publish its deferred writeback so the guest
        // bytes being shown are the rendered frame, not stale contents.
        const pitch_pixels = if (buffer.pitch_in_pixels != 0) buffer.pitch_in_pixels else buffer.width;
        const row_bytes = @as(usize, pitch_pixels) * 4;
        const needed = row_bytes * buffer.height;
        self.flushPendingGuestWrite(buffer.address, needed) catch |err| {
            self.last_flip_error = err;
            return false;
        };
        self.guest_frame_scratch.resize(self.allocator, needed) catch return false;

        const memory = self.guest_memory orelse return false;
        if (!memory.read(memory.context, buffer.address, self.guest_frame_scratch.items)) return false;

        // Prefer last GPU writeback when the display slot is still cleared /
        // not yet filled by the title (common while multi-draw is stuck after
        // the first completed frame).
        const guest_nz = countNonzeroRgba(self.guest_frame_scratch.items);
        if (guest_nz == 0) {
            if (self.latest_frame_index) |idx| {
                if (idx < self.completed_frames.items.len) {
                    const cached = &self.completed_frames.items[idx];
                    if (cached.pixels.items.len != 0 and countNonzeroRgba(cached.pixels.items) != 0) {
                        self.maybeDumpProgressFrame(
                            cached.pixels.items,
                            cached.width,
                            cached.height,
                            cached.width * 4,
                        );
                        return sink.present(sink.context, .{
                            .pixels = cached.pixels.items,
                            .width = cached.width,
                            .height = cached.height,
                            .row_pitch_bytes = cached.width * 4,
                            .guest_address = cached.guest_address,
                            .flip = flip,
                        });
                    }
                }
            }
        }

        self.maybeDumpProgressFrame(
            self.guest_frame_scratch.items,
            buffer.width,
            buffer.height,
            @intCast(row_bytes),
        );
        return sink.present(sink.context, .{
            .pixels = self.guest_frame_scratch.items,
            .width = buffer.width,
            .height = buffer.height,
            .row_pitch_bytes = @intCast(row_bytes),
            .guest_address = buffer.address,
            .flip = flip,
        });
    }

    fn maybeDumpProgressFrame(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        row_pitch_bytes: u32,
    ) void {
        if (row_pitch_bytes != width * 4) return;
        if (shouldDumpProgressFrame(self.flip_callbacks)) {
            var path_buffer: [64]u8 = undefined;
            const path: ?[:0]u8 = std.fmt.bufPrintZ(
                &path_buffer,
                "out\\frame-{d:0>4}.ppm",
                .{self.flip_callbacks},
            ) catch null;
            if (path) |name| {
                dumpFramePpm(name.ptr, width, height, pixels);
                std.debug.print(
                    "[vulkan dcb] dumped progress frame {d} ({d}x{d})\n",
                    .{ self.flip_callbacks, width, height },
                );
            }
        }
    }

    fn reportFrameProfile(self: *Renderer) void {
        const profile = self.frame_profile;
        const now = hostTimestampNs();
        if (self.frame_rate_sink) |sink| {
            if (self.frame_rate_counter.note(now)) |fps_tenths| {
                sink.update(sink.context, fps_tenths);
            }
        }
        const interval_ns = if (now != 0 and self.last_flip_profile_ns != 0 and now >= self.last_flip_profile_ns)
            now - self.last_flip_profile_ns
        else
            0;
        self.last_flip_profile_ns = now;
        const should_print = self.flip_callbacks <= 8 or
            self.flip_callbacks % 60 == 0 or
            interval_ns >= std.time.ns_per_s or
            profile.fence_wait_ns >= std.time.ns_per_s;
        if (should_print) {
            std.debug.print(
                "[gpu frame] flip={d} frame_ms={d} draws={d}/{d}ms dispatches={d}/{d}ms submits={d} fence_wait_us={d} upload_kib={d}(buf={d},rt={d},tex={d},idx={d}) resident_kib={d} readback_kib={d}(buf={d},rt={d}) storage_ms={d}+{d} target_ms={d} rt_hit={d} rt_miss={d} buf_cache={d} tex_cache={d}\n",
                .{
                    self.flip_callbacks,
                    interval_ns / std.time.ns_per_ms,
                    profile.draws,
                    profile.draw_ns / std.time.ns_per_ms,
                    profile.dispatches,
                    profile.dispatch_ns / std.time.ns_per_ms,
                    profile.submits,
                    profile.fence_wait_ns / std.time.ns_per_us,
                    profile.upload_bytes / 1024,
                    profile.storage_upload_bytes / 1024,
                    profile.target_upload_bytes / 1024,
                    profile.texture_upload_bytes / 1024,
                    profile.index_upload_bytes / 1024,
                    profile.resident_storage_bytes / 1024,
                    profile.readback_bytes / 1024,
                    profile.storage_readback_bytes / 1024,
                    profile.target_readback_bytes / 1024,
                    profile.storage_stage_ns / std.time.ns_per_ms,
                    profile.storage_commit_ns / std.time.ns_per_ms,
                    profile.target_materialize_ns / std.time.ns_per_ms,
                    profile.render_target_hits,
                    profile.render_target_misses,
                    self.guest_buffers.items.len,
                    self.sampled_image_cache.items.len,
                },
            );
            std.debug.print(
                "[gpu shaders] flip={d} pso_hit={d} pso_miss={d}/{d}ms pso_cache={d} miss_match(state/vs/ps)={d}/{d}/{d} sa_hit={d} sa_miss={d}/{d}ms prov_ms={d} xlat_ms={d} res_ms={d} probe_ms={d}\n",
                .{
                    self.flip_callbacks,
                    profile.graphics_pipeline_hits,
                    profile.graphics_pipeline_misses,
                    profile.graphics_pipeline_build_ns / std.time.ns_per_ms,
                    self.graphics_pipelines.items.len,
                    profile.graphics_pipeline_miss_state_match,
                    profile.graphics_pipeline_miss_vertex_match,
                    profile.graphics_pipeline_miss_fragment_match,
                    profile.shader_analysis_hits,
                    profile.shader_analysis_misses,
                    profile.shader_analysis_ns / std.time.ns_per_ms,
                    profile.scalar_provenance_ns / std.time.ns_per_ms,
                    profile.shader_translate_ns / std.time.ns_per_ms,
                    profile.graphics_resource_ns / std.time.ns_per_ms,
                    profile.texture_probe_ns / std.time.ns_per_ms,
                },
            );
        }
        self.frame_profile.reset();
    }

    fn discardPendingTargetlessDraw(self: *Renderer) void {
        self.pending_targetless_draws.clearRetainingCapacity();
    }

    fn resolvePendingTargetlessDraw(self: *Renderer, buffer: DisplayBuffer) void {
        if (self.pending_targetless_draws.items.len == 0) return;
        defer self.pending_targetless_draws.clearRetainingCapacity();
        const target = displayColorTarget(buffer) orelse {
            self.last_draw_error = Error.UnsupportedColorTarget;
            if (self.shouldReportDrawError(Error.UnsupportedColorTarget)) {
                std.debug.print(
                    "[vulkan dcb] deferred display draw rejected: invalid display buffer 0x{x} {d}x{d} pitch={d} tile={d}\n",
                    .{ buffer.address, buffer.width, buffer.height, buffer.pitch_in_pixels, buffer.tiling_mode },
                );
            }
            return;
        };
        var resolved: usize = 0;
        for (self.pending_targetless_draws.items) |*pending| {
            self.drawGuestGraphics(&pending.state, pending.draw, pending.vertex_stage, target) catch |err| {
                self.last_draw_error = err;
                if (self.shouldReportDrawError(err)) {
                    std.debug.print("[vulkan dcb] deferred display draw rejected: {s}\n", .{@errorName(err)});
                }
                continue;
            };
            self.guest_graphics_draws += 1;
            self.translated_draws += 1;
            self.targetless_draws_resolved += 1;
            resolved += 1;
        }
        if (resolved == 0) return;
        self.last_draw_error = null;
        if (self.targetless_draws_resolved == resolved or log_verbose_gpu) {
            std.debug.print(
                "[vulkan dcb] deferred display pass ok: draws={d} target=0x{x} {d}x{d} tile={d}\n",
                .{ resolved, buffer.address, buffer.width, buffer.height, buffer.tiling_mode },
            );
        }
    }

    fn appendPendingTargetlessDraw(
        self: *Renderer,
        state: *const gpu.State,
        draw: GuestDraw,
        vertex_stage: gpu.resources.ShaderStage,
    ) void {
        if (self.pending_targetless_draws.items.len >= maximum_pending_targetless_draws) {
            self.last_draw_error = Error.UnsupportedColorTarget;
            if (self.shouldReportDrawError(Error.UnsupportedColorTarget)) {
                std.debug.print(
                    "[vulkan dcb] targetless display pass exceeds {d} draws; dropping later work\n",
                    .{maximum_pending_targetless_draws},
                );
            }
            return;
        }
        self.pending_targetless_draws.append(self.allocator, .{
            .state = state.*,
            .draw = draw,
            .vertex_stage = vertex_stage,
        }) catch |err| {
            self.last_draw_error = err;
            if (self.shouldReportDrawError(err)) {
                std.debug.print("[vulkan dcb] targetless draw skipped: {s}\n", .{@errorName(err)});
            }
            return;
        };
        self.targetless_draws_deferred += 1;
        self.last_draw_error = null;
        if (self.targetless_draws_deferred == 1 or log_verbose_gpu) {
            std.debug.print("[vulkan dcb] deferred targetless display pass until flip\n", .{});
        }
    }

    fn dcbFlip(context: ?*anyopaque, flip: gpu.state.Flip) bool {
        const self = fromContext(context);
        self.flip_callbacks += 1;
        defer self.reportFrameProfile();
        // Content probes only hold within the frame they were taken in.
        defer self.texture_probe_count = 0;
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] flip #{d} buffer={d} video_out={d} completed_frames={d}\n",
            .{ self.flip_callbacks, flip.display_buffer_index, flip.video_out_handle, self.completed_frames.items.len },
        );
        // A display flip consumes the host attachment directly.  Materialize
        // only the selected target; tiling it back into guest memory is reserved
        // for a real CPU-visible synchronization point.
        var selected_index: ?usize = null;
        var requested: ?DisplayBuffer = null;
        if (self.display_buffer_resolver) |resolver| {
            requested = resolver.resolve(resolver.context, flip) orelse {
                self.last_flip_error = Error.MissingPresentedFrame;
                return false;
            };
            self.resolvePendingTargetlessDraw(requested.?);
            // Until the merged Unity quad path can compose the decoded movie
            // into its older camera target, present the newest proven video
            // surface directly. The override expires as soon as planar video
            // draws stop, so menus/gameplay resume using the requested buffer.
            if (self.window_presentation != null and
                self.latest_video_render_target_index != null and
                self.flip_callbacks -| self.video_surface_last_flip <= 2)
            {
                const video_index = self.latest_video_render_target_index.?;
                if (video_index < self.render_targets.items.len and
                    self.render_targets.items[video_index].initialized)
                {
                    self.blitRenderTargetToSwapchain(video_index) catch |err| {
                        self.last_flip_error = err;
                        return false;
                    };
                    if (self.flip_callbacks <= 24 or log_verbose_gpu) {
                        std.debug.print(
                            "[vulkan dcb] presenting active video target @0x{x}\n",
                            .{self.render_targets.items[video_index].target.descriptor.address},
                        );
                    }
                    self.presented_frames += 1;
                    self.last_flip_error = null;
                    return true;
                }
            }
            // Most frames can go directly from the resident render target to
            // the swapchain. At a handful of diagnostic checkpoints take the
            // normal materialization path so the PPM is the frame that was
            // actually presented, not stale guest memory.
            if (self.window_presentation != null and
                !shouldDumpProgressFrame(self.flip_callbacks))
            {
                for (self.render_targets.items, 0..) |target, target_index| {
                    if (target.target.descriptor.address != requested.?.address or !target.initialized) continue;
                    self.blitRenderTargetToSwapchain(target_index) catch |err| {
                        self.last_flip_error = err;
                        return false;
                    };
                    self.presented_frames += 1;
                    self.last_flip_error = null;
                    return true;
                }
            }
            _ = self.materializeRenderTargetAt(requested.?.address) catch |err| {
                self.last_flip_error = err;
                return false;
            };
            for (self.completed_frames.items, 0..) |cached, index| {
                if (cached.guest_address == requested.?.address) {
                    selected_index = index;
                    break;
                }
            }
        } else if (self.latest_render_target_index) |target_index| {
            self.materializeRenderTarget(target_index) catch |err| {
                self.last_flip_error = err;
                return false;
            };
            selected_index = self.latest_frame_index;
        } else {
            selected_index = self.latest_frame_index;
        }

        const frame_index = selected_index orelse {
            // A flip naming a buffer nothing has rendered into is not an error.
            // A title shows its first buffer before it draws anything, and
            // hardware displays whatever that buffer holds. Refusing here is
            // what stops such a title dead: no completion is published, its
            // render thread waits for one, and it never reaches the drawing
            // that would have produced a frame to show. So the buffer is read
            // and shown as it stands.
            if (requested) |buffer| {
                if (self.presentGuestBuffer(buffer, flip)) {
                    self.presented_frames += 1;
                    self.last_flip_error = null;
                    return true;
                }
            }
            self.last_flip_error = Error.MissingPresentedFrame;
            return false;
        };
        const cached = &self.completed_frames.items[frame_index];
        if (cached.pixels.items.len == 0) {
            self.last_flip_error = Error.MissingPresentedFrame;
            return false;
        }
        self.maybeDumpProgressFrame(
            cached.pixels.items,
            cached.width,
            cached.height,
            cached.width * 4,
        );
        if (self.presentation_sink) |sink| {
            if (!sink.present(sink.context, .{
                .pixels = cached.pixels.items,
                .width = cached.width,
                .height = cached.height,
                .row_pitch_bytes = cached.width * 4,
                .guest_address = cached.guest_address,
                .flip = flip,
            })) {
                self.last_flip_error = Error.PresentationRejected;
                return false;
            }
        }
        self.presented_frames += 1;
        self.last_flip_error = null;
        return true;
    }

    /// VS program bank for a draw. NGG/export paths publish the vertex program
    /// in the ES (export) registers rather than the classic VS bank; geometry
    /// is a last resort for the same reason.
    fn graphicsVertexStage(state: *const gpu.State) ?gpu.resources.ShaderStage {
        for ([_]gpu.resources.ShaderStage{ .vertex, .export_shader, .geometry }) |stage| {
            if (stage.programAddress(state) != null) return stage;
        }
        return null;
    }

    /// Shader translation failures are keyed by program and stage. A command
    /// buffer may issue the same unsupported draw thousands of times; printing
    /// the full disassembly for each one can cost more wall time than the GPU.
    fn shouldReportShaderFailure(
        self: *Renderer,
        address: u64,
        stage: gpu.resources.ShaderStage,
        err: anyerror,
    ) bool {
        for (&self.reported_shader_failures) |*reported| {
            if (reported.* == null) {
                reported.* = .{ .address = address, .stage = stage, .err = err };
                return true;
            }
            if (reported.*.?.address == address and
                reported.*.?.stage == stage and
                reported.*.?.err == err)
            {
                return false;
            }
        }
        return false;
    }

    fn shouldReportVertexResources(self: *Renderer, address: u64) bool {
        for (&self.reported_vertex_resource_programs) |*reported| {
            if (reported.* == address) return false;
            if (reported.* == 0) {
                reported.* = address;
                return true;
            }
        }
        return false;
    }

    fn shouldReportFragmentResources(self: *Renderer, address: u64) bool {
        for (&self.reported_fragment_resource_programs) |*reported| {
            if (reported.* == address) return false;
            if (reported.* == 0) {
                reported.* = address;
                return true;
            }
        }
        return false;
    }

    fn shouldReportDrawError(self: *Renderer, err: anyerror) bool {
        for (&self.reported_draw_errors) |*reported| {
            if (reported.* == null) {
                reported.* = err;
                return true;
            }
            if (reported.*.? == err) return false;
        }
        return false;
    }

    fn shouldReportComputeShaderFailure(self: *Renderer, address: u64, err: anyerror) bool {
        for (&self.reported_compute_shader_failures) |*reported| {
            if (reported.* == null) {
                reported.* = .{ .address = address, .err = err };
                return true;
            }
            if (reported.*.?.address == address and reported.*.?.err == err) return false;
        }
        return false;
    }

    fn shouldReportComputeResources(self: *Renderer, address: u64) bool {
        for (&self.reported_compute_resource_programs) |*reported| {
            if (reported.* == address) return false;
            if (reported.* == 0) {
                reported.* = address;
                return true;
            }
        }
        return false;
    }

    fn dcbDraw(context: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
        const self = fromContext(context);
        const profile_started = hostTimestampNs();
        defer self.frame_profile.draw_ns +|= elapsedHostNanoseconds(profile_started);
        self.draw_callbacks += 1;
        self.frame_profile.draws += 1;
        const vertex_stage = graphicsVertexStage(state);
        const has_vertex = vertex_stage != null;
        const has_fragment = gpu.resources.ShaderStage.pixel.programAddress(state) != null;
        if (!has_vertex and !has_fragment and !self.graphics_probe_enabled) return true;

        // AGC's DRAW_INDEX_2 body is max_size, index_va_lo/hi, index_count,
        // draw_initiator — the same layout bootstrap services emit. AUTO is the
        // non-indexed count form used by the diagnostic triangle probe.
        const draw: GuestDraw = if (packet.opcode == gpu.pm4.draw_index_auto and packet.body.len >= 1)
            .{ .vertex_count = packet.body[0] }
        else if (packet.opcode == gpu.pm4.draw_index_2 and packet.body.len >= 5)
            .{
                .index_count = packet.body[3],
                .index_address = (@as(u64, packet.body[2]) << 32) | packet.body[1],
                // AGC index streams are 16-bit by default; 32-bit shows up as
                // INDEX_TYPE later and is not tracked in GPU state yet.
                .index_uint32 = false,
            }
        else if (packet.opcode == gpu.pm4.draw_index_offset_2 and packet.body.len >= 4)
            .{
                .index_count = packet.body[2],
                .index_address = state.index_base_address +| (@as(u64, packet.body[1]) * switch (state.index_type) {
                    0 => @as(u64, 2),
                    1 => @as(u64, 4),
                    2 => @as(u64, 1),
                    3 => @as(u64, 2),
                }),
                .index_uint32 = state.index_type == 1,
            }
        else {
            self.last_draw_error = Error.UnsupportedDrawPacket;
            std.debug.print(
                "[vulkan dcb] draw rejected: {s} (opcode=0x{x}, body={d})\n",
                .{ @errorName(Error.UnsupportedDrawPacket), packet.opcode, packet.body.len },
            );
            return false;
        };

        // Vertex-only or pixel-only draws show up in pre-passes before both
        // stages are bound. Rejecting them aborts the DCB; accepting as a no-op
        // lets the queue reach a complete pair (and later the flip).
        if (has_vertex != has_fragment) {
            self.last_draw_error = Error.MissingGraphicsProgram;
            if (self.shouldReportDrawError(Error.MissingGraphicsProgram)) {
                std.debug.print(
                    "[vulkan dcb] draw skipped: incomplete graphics programs (vs={any} ps={any} vs_bank={s})\n",
                    .{
                        has_vertex,
                        has_fragment,
                        if (vertex_stage) |stage| @tagName(stage) else "none",
                    },
                );
            }
            return true;
        }
        if (has_vertex) {
            const render_state = gpu.resources.decodeRenderState(state);
            if (render_state.color_control.mode == 3) {
                const resolved = self.resolveColorTargets(render_state) catch |err| {
                    self.last_draw_error = err;
                    if (self.shouldReportDrawError(err)) {
                        std.debug.print("[vulkan dcb] color resolve skipped: {s}\n", .{@errorName(err)});
                    }
                    return true;
                };
                if (resolved) {
                    self.guest_graphics_draws += 1;
                    self.translated_draws += 1;
                    self.last_draw_error = null;
                    return true;
                }
            }
            if (render_state.active_color_count == 0) {
                self.appendPendingTargetlessDraw(state, draw, vertex_stage.?);
                return true;
            }
            self.discardPendingTargetlessDraw();
            self.drawGuestGraphics(state, draw, vertex_stage.?, null) catch |err| {
                self.last_draw_error = err;
                if (self.shouldReportDrawError(err)) {
                    std.debug.print("[vulkan dcb] draw rejected: {s}\n", .{@errorName(err)});
                    if (err == Error.UnsupportedColorTarget) {
                        const rejected_state = gpu.resources.decodeRenderState(state);
                        for (rejected_state.color_targets) |candidate| {
                            const target = candidate orelse continue;
                            if (!target.isActive()) continue;
                            std.debug.print(
                                "[vulkan dcb] rejected target slot={d} addr=0x{x} {d}x{d} pitch={d} fmt={d} num={d} swap={d} tile={s} samples={d} frags={d} dcc={any} cmask={any} fmask={any}\n",
                                .{
                                    target.slot,
                                    target.address,
                                    target.width,
                                    target.height,
                                    target.pitch,
                                    target.format,
                                    target.number_type,
                                    target.component_swap,
                                    @tagName(target.tile_mode),
                                    target.samples_log2,
                                    target.fragments_log2,
                                    target.dcc_enabled,
                                    target.cmask_fast_clear,
                                    target.fmask_compression,
                                },
                            );
                        }
                    }
                }
                // Soft-skip shader/state gaps so one incomplete draw does not
                // kill the DCB before a later flip.
                return true;
            };
        } else self.drawGraphicsProbe() catch |err| {
            self.last_draw_error = err;
            std.debug.print("[vulkan dcb] graphics probe rejected: {s}\n", .{@errorName(err)});
            return false;
        };
        if (has_vertex) self.guest_graphics_draws += 1;
        self.translated_draws += 1;
        self.last_draw_error = null;
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] draw ok: {s} (#{d})\n",
            .{ if (has_vertex) "guest" else "probe", self.translated_draws },
        );
        return true;
    }

    fn dcbDispatch(context: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
        const self = fromContext(context);
        const profile_started = hostTimestampNs();
        defer self.frame_profile.dispatch_ns +|= elapsedHostNanoseconds(profile_started);
        self.dispatch_callbacks += 1;
        self.frame_profile.dispatches += 1;
        if (self.skip_compute_dispatches) {
            self.last_dispatch_error = null;
            return true;
        }
        if (packet.opcode != gpu.pm4.dispatch_direct) {
            self.last_dispatch_error = Error.UnsupportedIndirectDispatch;
            std.debug.print("[vulkan dcb] dispatch rejected: {s}\n", .{@errorName(Error.UnsupportedIndirectDispatch)});
            return false;
        }
        if (packet.body.len < 3) {
            self.last_dispatch_error = Error.InvalidDispatchPacket;
            std.debug.print("[vulkan dcb] dispatch rejected: {s}\n", .{@errorName(Error.InvalidDispatchPacket)});
            return false;
        }
        const program_address = gpu.resources.ShaderStage.compute.programAddress(state) orelse {
            const first_missing = self.last_dispatch_error == null or
                self.last_dispatch_error.? != Error.MissingComputeProgram;
            self.last_dispatch_error = Error.MissingComputeProgram;
            // A reset/default-state packet may be followed by a dispatch that
            // has no executable program in the subset of state we retain.
            // Do not discard later graphics work and the frame's flip merely
            // because this one compute operation cannot be reproduced yet.
            if (first_missing) std.debug.print(
                "[vulkan dcb] dispatch skipped: {s} groups={d}x{d}x{d} pgm={?x}/{?x} rsrc={?x}/{?x}\n",
                .{
                    @errorName(Error.MissingComputeProgram),
                    packet.body[0],
                    packet.body[1],
                    packet.body[2],
                    state.readRegister(.shader, 0x20c),
                    state.readRegister(.shader, 0x20d),
                    state.readRegister(.shader, 0x212),
                    state.readRegister(.shader, 0x213),
                },
            );
            return true;
        };
        const local_size = [3]u32{
            computeLocalSize(state, 0x207),
            computeLocalSize(state, 0x208),
            computeLocalSize(state, 0x209),
        };
        const dispatch_dimensions = [3]u32{ packet.body[0], packet.body[1], packet.body[2] };
        const initiator = if (packet.body.len >= 4) packet.body[3] else 0;
        const group_count = dispatchGroupCounts(dispatch_dimensions, local_size, initiator);
        if (group_count[0] == 0 or group_count[1] == 0 or group_count[2] == 0) {
            self.last_dispatch_error = null;
            return true;
        }
        if (self.flip_callbacks == 240) {
            std.debug.print(
                "[vulkan dcb] dispatch trace next_flip={d} dispatch={d} program=0x{x} dimensions={d}x{d}x{d} groups={d}x{d}x{d} local={d}x{d}x{d} initiator=0x{x}\n",
                .{
                    self.flip_callbacks + 1,
                    self.frame_profile.dispatches,
                    program_address,
                    packet.body[0],
                    packet.body[1],
                    packet.body[2],
                    group_count[0],
                    group_count[1],
                    group_count[2],
                    local_size[0],
                    local_size[1],
                    local_size[2],
                    initiator,
                },
            );
        }
        _ = self.dispatchRdna2State(
            state,
            local_size,
            group_count,
        ) catch |err| {
            self.last_dispatch_error = err;
            // Soft-skip resource/translation gaps so one incomplete compute
            // kernel does not abort the DCB before later draws and flips.
            const soft = err == Error.MissingStorageDescriptor or
                err == Error.GuestMemoryReadFailed or
                err == Error.GuestBufferTooLarge or
                std.mem.eql(u8, @errorName(err), "AddressOverflow") or
                std.mem.eql(u8, @errorName(err), "UnsupportedOpcode") or
                std.mem.eql(u8, @errorName(err), "UndefinedRegister") or
                std.mem.eql(u8, @errorName(err), "InvalidStorageBinding") or
                std.mem.eql(u8, @errorName(err), "InvalidMetadata") or
                std.mem.eql(u8, @errorName(err), "UserDataOutOfRange");
            std.debug.print(
                "[vulkan dcb] dispatch {s}: {s} (groups={d}x{d}x{d})\n",
                .{
                    if (soft) "skipped" else "rejected",
                    @errorName(err),
                    packet.body[0],
                    packet.body[1],
                    packet.body[2],
                },
            );
            return soft;
        };
        self.translated_dispatches += 1;
        self.last_dispatch_error = null;
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] dispatch ok: groups={d}x{d}x{d} local={d}x{d}x{d} (#{d})\n",
            .{
                packet.body[0],
                packet.body[1],
                packet.body[2],
                local_size[0],
                local_size[1],
                local_size[2],
                self.translated_dispatches,
            },
        );
        return true;
    }
};

var fallback_release_counter: std.atomic.Value(u64) = .init(0);

/// A monotonic stand-in for the GPU/system clocks sampled by RELEASE_MEM.
///
/// The renderer currently completes submissions synchronously, so sampling the
/// invariant host counter after `vkDeviceWaitIdle` preserves the ordering and
/// progress properties titles rely on. A Vulkan timestamp query can replace
/// this value when command submission becomes asynchronous.
fn releaseTimestampCounter() u64 {
    if (builtin.cpu.arch != .x86_64) return fallback_release_counter.fetchAdd(1, .monotonic) + 1;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

fn registerOperand(op: gpu.ShaderOperand, kind: gpu.ShaderOperandKind, register: u32) bool {
    return op.kind == kind and op.reg == register;
}

fn inlineIntegerOperand(op: gpu.ShaderOperand, value: u32) bool {
    return op.kind == .integer_inline_constant and op.value == value;
}

fn matchesRgbaImageClear(inst: anytype) bool {
    if (inst.len != 11 or
        inst[0].opcode != .v_lshl_add_u32 or
        inst[1].opcode != .s_buffer_load_dwordx4 or
        inst[2].opcode != .v_lshl_add_u32 or
        inst[3].opcode != .v_mov_b32 or
        inst[4].opcode != .s_waitcnt or
        inst[5].opcode != .v_mov_b32 or
        inst[6].opcode != .v_mov_b32 or
        inst[7].opcode != .v_mov_b32 or
        inst[8].opcode != .v_mov_b32 or
        inst[9].opcode != .image_store or
        inst[10].opcode != .s_endpgm)
    {
        return false;
    }
    if (!registerOperand(inst[0].dst, .vgpr, 4) or
        !registerOperand(inst[0].src0, .sgpr, 12) or
        !inlineIntegerOperand(inst[0].src1, 3) or
        !registerOperand(inst[0].src2, .vgpr, 0) or
        !registerOperand(inst[1].dst, .sgpr, 16) or
        !registerOperand(inst[1].src0, .sgpr, 8) or inst[1].memory_offset != 0 or
        !registerOperand(inst[2].dst, .vgpr, 5) or
        !registerOperand(inst[2].src0, .sgpr, 13) or
        !inlineIntegerOperand(inst[2].src1, 3) or
        !registerOperand(inst[2].src2, .vgpr, 1) or
        !registerOperand(inst[3].dst, .vgpr, 6) or
        !registerOperand(inst[3].src0, .sgpr, 14))
    {
        return false;
    }
    for (5..9) |index| {
        const channel: u32 = @intCast(index - 5);
        if (!registerOperand(inst[index].dst, .vgpr, channel) or
            !registerOperand(inst[index].src0, .sgpr, 16 + channel)) return false;
    }
    return registerOperand(inst[9].dst, .vgpr, 0) and
        registerOperand(inst[9].src0, .vgpr, 4) and
        registerOperand(inst[9].src1, .sgpr, 0) and
        inst[9].data_mask == 0xf and inst[9].image_nsa_words == 0;
}

fn matchesScalarImageClear(inst: anytype) bool {
    if (inst.len != 8 or
        inst[0].opcode != .v_lshl_add_u32 or
        inst[1].opcode != .s_buffer_load_dword or
        inst[2].opcode != .s_waitcnt or
        inst[3].opcode != .v_mov_b32 or
        inst[4].opcode != .v_lshl_add_u32 or
        inst[5].opcode != .v_mov_b32 or
        inst[6].opcode != .image_store or
        inst[7].opcode != .s_endpgm)
    {
        return false;
    }
    return registerOperand(inst[0].dst, .vgpr, 0) and
        registerOperand(inst[0].src0, .sgpr, 12) and
        inlineIntegerOperand(inst[0].src1, 3) and
        registerOperand(inst[0].src2, .vgpr, 0) and
        inst[1].dst.kind == .vcc_lo and registerOperand(inst[1].src0, .sgpr, 8) and
        inst[1].memory_offset == 0 and
        registerOperand(inst[3].dst, .vgpr, 2) and inst[3].src0.kind == .vcc_lo and
        registerOperand(inst[4].dst, .vgpr, 1) and
        registerOperand(inst[4].src0, .sgpr, 13) and
        inlineIntegerOperand(inst[4].src1, 3) and
        registerOperand(inst[4].src2, .vgpr, 1) and
        registerOperand(inst[5].dst, .vgpr, 3) and registerOperand(inst[5].src0, .sgpr, 14) and
        registerOperand(inst[6].dst, .vgpr, 2) and
        registerOperand(inst[6].src0, .vgpr, 0) and
        registerOperand(inst[6].src1, .sgpr, 0) and
        inst[6].data_mask == 0x1 and inst[6].image_nsa_words == 1;
}

fn matchesDualImageClear(inst: anytype) bool {
    if (inst.len != 18) return false;
    const expected = [_]gpu.ShaderOpcode{
        .s_inst_prefetch,
        .v_lshl_add_u32,
        .s_buffer_load_dwordx4,
        .v_lshl_add_u32,
        .s_waitcnt,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .s_load_dwordx8,
        .image_store,
        .s_waitcnt,
        .image_store,
        .s_endpgm,
    };
    for (expected, inst) |opcode, instruction| {
        if (instruction.opcode != opcode) return false;
    }
    if (!registerOperand(inst[1].dst, .vgpr, 8) or
        !registerOperand(inst[1].src0, .sgpr, 14) or
        !inlineIntegerOperand(inst[1].src1, 2) or
        !registerOperand(inst[1].src2, .vgpr, 0) or
        !registerOperand(inst[2].dst, .sgpr, 16) or
        !registerOperand(inst[2].src0, .sgpr, 8) or inst[2].memory_offset != 384 or
        !registerOperand(inst[3].dst, .vgpr, 9) or
        !registerOperand(inst[3].src0, .sgpr, 15) or
        !inlineIntegerOperand(inst[3].src1, 2) or
        !registerOperand(inst[3].src2, .vgpr, 1))
    {
        return false;
    }
    for (5..8) |index| {
        const channel: u32 = @intCast(index - 5);
        if (!registerOperand(inst[index].dst, .vgpr, channel) or
            !registerOperand(inst[index].src0, .sgpr, 16 + channel)) return false;
    }
    if (!registerOperand(inst[8].dst, .vgpr, 3) or
        inst[8].src0.kind != .float_inline_constant or
        inst[8].src0.value != @as(u32, @bitCast(@as(f32, -1.0))))
    {
        return false;
    }
    for (9..12) |index| {
        const channel: u32 = @intCast(index - 9 + 4);
        if (!registerOperand(inst[index].dst, .vgpr, channel) or
            !inlineIntegerOperand(inst[index].src0, 0)) return false;
    }
    if (!registerOperand(inst[12].dst, .vgpr, 7) or
        inst[12].src0.kind != .float_inline_constant or
        inst[12].src0.value != @as(u32, @bitCast(@as(f32, -1.0))) or
        !registerOperand(inst[13].dst, .sgpr, 24) or
        !registerOperand(inst[13].src0, .sgpr, 12) or inst[13].memory_offset != 0)
    {
        return false;
    }
    return registerOperand(inst[14].dst, .vgpr, 0) and
        registerOperand(inst[14].src0, .vgpr, 8) and
        registerOperand(inst[14].src1, .sgpr, 0) and
        inst[14].data_mask == 0xf and inst[14].image_nsa_words == 0 and
        inst[14].image_dimension == .dim_2d and
        registerOperand(inst[16].dst, .vgpr, 4) and
        registerOperand(inst[16].src0, .vgpr, 8) and
        registerOperand(inst[16].src1, .sgpr, 24) and
        inst[16].data_mask == 0xf and inst[16].image_nsa_words == 0 and
        inst[16].image_dimension == .dim_2d;
}

fn matchesFullscreenSampleBlit(inst: anytype) bool {
    if (inst.len < 12 or inst.len > 20) return false;
    var samples: u32 = 0;
    var color_exports: u32 = 0;
    for (inst) |candidate| {
        if (candidate.opcode == .image_sample) {
            if (candidate.data_mask != 0xf) return false;
            samples += 1;
        }
        if (candidate.opcode == .image_store) return false;
        if (candidate.opcode == .exp and candidate.export_target == 0) {
            if (!candidate.export_done) return false;
            color_exports += 1;
        }
    }
    return samples == 1 and color_exports == 1;
}

fn matchesWholeImageCopy(inst: anytype) bool {
    if (inst.len != 22) return false;
    const expected = [_]gpu.ShaderOpcode{
        .s_inst_prefetch,
        .v_lshl_add_u32,
        .s_buffer_load_dwordx2,
        .v_lshl_add_u32,
        .s_waitcnt,
        .v_cmpx_gt_u32,
        .v_cmpx_gt_u32,
        .s_cbranch_execz,
        .v_mov_b32,
        .s_buffer_load_dwordx2,
        .s_waitcnt,
        .v_add_nc_u32,
        .v_add_nc_u32,
        .s_buffer_load_dwordx2,
        .s_waitcnt,
        .v_add_nc_u32,
        .v_add_nc_u32,
        .s_load_dwordx8,
        .image_load,
        .s_waitcnt,
        .image_store,
        .s_endpgm,
    };
    for (expected, inst) |opcode, instruction| {
        if (instruction.opcode != opcode) return false;
    }
    // Descriptor resolution and the six control words below validate the
    // concrete resources and copy rectangle.  Operand aliases vary between
    // compiler revisions (notably VCC and the 2D/2D-array MIMG spelling), so
    // the complete opcode/control-flow shape is the stable kernel identity.
    return true;
}

fn matchesVolumeBufferCopy(inst: anytype) bool {
    if (inst.len != 32) return false;
    const expected = [_]@TypeOf(inst[0].opcode){
        .s_inst_prefetch,
        .v_lshl_add_u32,
        .s_buffer_load_dwordx4,
        .v_lshl_add_u32,
        .s_waitcnt,
        .v_cmpx_lt_u32,
        .v_cmpx_gt_u32,
        .v_cmpx_gt_u32,
        .s_cbranch_execz,
        .s_buffer_load_dwordx2,
        .s_waitcnt,
        .v_mul_lo_u32,
        .v_mul_lo_u32,
        .s_buffer_load_dword,
        .s_waitcnt,
        .s_mul_i32,
        .s_buffer_load_dwordx4,
        .s_waitcnt,
        .v_add_nc_u32,
        .v_add3_u32,
        .v_add_nc_u32,
        .v_add_nc_u32,
        .v_add_nc_u32,
        .v_add_nc_u32,
        .v_add_nc_u32,
        .buffer_load_format_x,
        .buffer_load_format_x,
        .buffer_load_format_x,
        .buffer_load_format_x,
        .s_waitcnt,
        .image_store,
        .s_endpgm,
    };
    for (expected, inst) |opcode, instruction| {
        if (instruction.opcode != opcode) return false;
    }
    if (!registerOperand(inst[1].dst, .vgpr, 1) or
        !registerOperand(inst[1].src0, .sgpr, 17) or
        !inlineIntegerOperand(inst[1].src1, 3) or
        !registerOperand(inst[1].src2, .vgpr, 1) or
        !registerOperand(inst[2].dst, .sgpr, 20) or
        !registerOperand(inst[2].src0, .sgpr, 12) or inst[2].memory_offset != 32 or
        !registerOperand(inst[3].dst, .vgpr, 3) or
        !registerOperand(inst[3].src0, .sgpr, 16) or
        !inlineIntegerOperand(inst[3].src1, 3) or
        !registerOperand(inst[3].src2, .vgpr, 0) or
        inst[5].dst.kind != .exec_lo or !registerOperand(inst[5].src0, .sgpr, 18) or
        !registerOperand(inst[5].src1, .sgpr, 22) or
        inst[6].dst.kind != .exec_lo or !registerOperand(inst[6].src0, .sgpr, 21) or
        !registerOperand(inst[6].src1, .vgpr, 1) or
        inst[7].dst.kind != .exec_lo or !registerOperand(inst[7].src0, .sgpr, 20) or
        !registerOperand(inst[7].src1, .vgpr, 3) or
        inst[9].dst.kind != .vcc_lo or !registerOperand(inst[9].src0, .sgpr, 12) or
        inst[9].memory_offset != 0 or
        !registerOperand(inst[11].dst, .vgpr, 0) or inst[11].src0.kind != .vcc_lo or
        !registerOperand(inst[11].src1, .vgpr, 1) or
        !registerOperand(inst[12].dst, .vgpr, 2) or inst[12].src0.kind != .vcc_hi or
        !registerOperand(inst[12].src1, .vgpr, 3) or
        inst[13].dst.kind != .vcc_lo or !registerOperand(inst[13].src0, .sgpr, 12) or
        inst[13].memory_offset != 8 or
        inst[15].dst.kind != .vcc_lo or inst[15].src0.kind != .vcc_lo or
        !registerOperand(inst[15].src1, .sgpr, 18) or
        !registerOperand(inst[16].dst, .sgpr, 20) or
        !registerOperand(inst[16].src0, .sgpr, 12) or inst[16].memory_offset != 16)
    {
        return false;
    }
    if (!registerOperand(inst[18].dst, .vgpr, 4) or
        !registerOperand(inst[18].src0, .sgpr, 20) or
        !registerOperand(inst[18].src1, .vgpr, 3) or
        !registerOperand(inst[19].dst, .vgpr, 0) or inst[19].src0.kind != .vcc_lo or
        !registerOperand(inst[19].src1, .vgpr, 2) or
        !registerOperand(inst[19].src2, .vgpr, 0) or
        !registerOperand(inst[20].dst, .vgpr, 5) or
        !registerOperand(inst[20].src0, .sgpr, 21) or
        !registerOperand(inst[20].src1, .vgpr, 1) or
        !registerOperand(inst[21].dst, .vgpr, 6) or
        !registerOperand(inst[21].src0, .sgpr, 18) or
        !registerOperand(inst[21].src1, .sgpr, 22))
    {
        return false;
    }
    for (22..25) |index| {
        const channel: u32 = @intCast(index - 21);
        if (!registerOperand(inst[index].dst, .vgpr, channel) or
            !inlineIntegerOperand(inst[index].src0, channel) or
            !registerOperand(inst[index].src1, .vgpr, 0)) return false;
    }
    for (25..29) |index| {
        const channel: u32 = @intCast(index - 25);
        if (!registerOperand(inst[index].dst, .vgpr, channel) or
            !registerOperand(inst[index].src0, .vgpr, channel) or
            !registerOperand(inst[index].src1, .sgpr, 8) or
            !inst[index].index_enable or inst[index].offset_enable or
            inst[index].memory_offset != 0) return false;
    }
    return registerOperand(inst[30].dst, .vgpr, 0) and
        registerOperand(inst[30].src0, .vgpr, 4) and
        registerOperand(inst[30].src1, .sgpr, 0) and
        inst[30].data_mask == 0xf and inst[30].image_nsa_words == 0 and
        inst[30].image_dimension == .dim_3d;
}

fn volumeSourceIndex(strides: [3]u32, x: u32, y: u32, z: u32) error{Overflow}!u64 {
    const x_offset = std.math.mul(u64, strides[1], x) catch return error.Overflow;
    const y_offset = std.math.mul(u64, strides[0], y) catch return error.Overflow;
    const z_offset = std.math.mul(u64, strides[2], z) catch return error.Overflow;
    const xy = std.math.add(u64, x_offset, y_offset) catch return error.Overflow;
    return std.math.add(u64, xy, z_offset) catch return error.Overflow;
}

fn readTypedBufferValue(memory: GuestMemory, descriptor: gpu.BufferDescriptor, index: u64) Error!u32 {
    if (index >= descriptor.record_count) return 0;
    const byte_offset = std.math.mul(u64, index, descriptor.stride) catch
        return Error.GuestBufferTooLarge;
    const address = std.math.add(u64, descriptor.address, byte_offset) catch
        return Error.GuestMemoryReadFailed;
    return switch (descriptor.unified_format) {
        5 => blk: {
            var byte: [1]u8 = undefined;
            if (!memory.read(memory.context, address, &byte)) return Error.GuestMemoryReadFailed;
            break :blk byte[0];
        },
        11 => blk: {
            var bytes: [2]u8 = undefined;
            if (!memory.read(memory.context, address, &bytes)) return Error.GuestMemoryReadFailed;
            break :blk std.mem.readInt(u16, &bytes, .little);
        },
        else => return Error.InvalidStorageDescriptor,
    };
}

fn resolveReadWriteImageDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    resource_sgpr: u32,
) anyerror!?gpu.ImageDescriptor {
    if (try bindings.inlineImageDescriptor(resource_sgpr)) |descriptor| return descriptor;
    const binding = (try bindings.resolve(reader, .read_write_texture, 0)) orelse return null;
    return binding.descriptor.read_write_texture;
}

fn imageDescriptorFromUserDataPointer(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    pointer_sgpr: u32,
) anyerror!?gpu.ImageDescriptor {
    if (pointer_sgpr < bindings.scalar_user_data_base) return null;
    const first: usize = pointer_sgpr - bindings.scalar_user_data_base;
    if (first + 2 > bindings.user_data_count) return null;
    const low = bindings.user_data[first];
    const high = bindings.user_data[first + 1];
    if (high & 0xffff_0000 != 0) return null;
    const address = @as(u64, low) | (@as(u64, high) << 32);
    if (address == 0) return null;
    var words: [8]u32 = undefined;
    try reader.readWords(address, &words);
    return try gpu.resources.decodeImageDescriptor(&words);
}

fn samplerDescriptorFromUserDataPointer(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    pointer_sgpr: u32,
) anyerror!?gpu.resources.SamplerDescriptor {
    if (pointer_sgpr < bindings.scalar_user_data_base) return null;
    const first: usize = pointer_sgpr - bindings.scalar_user_data_base;
    if (first + 2 > bindings.user_data_count) return null;
    const low = bindings.user_data[first];
    const high = bindings.user_data[first + 1];
    if (high & 0xffff_0000 != 0) return null;
    const address = @as(u64, low) | (@as(u64, high) << 32);
    if (address == 0) return null;
    var words: [4]u32 = undefined;
    try reader.readWords(address, &words);
    return try gpu.resources.decodeSamplerDescriptor(&words);
}

fn bufferDescriptorFromUserDataPointer(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    pointer_sgpr: u32,
    byte_offset: i32,
) anyerror!?gpu.BufferDescriptor {
    if (pointer_sgpr < bindings.scalar_user_data_base) return null;
    const first: usize = pointer_sgpr - bindings.scalar_user_data_base;
    if (first + 2 > bindings.user_data_count) return null;
    const low = bindings.user_data[first];
    const high = bindings.user_data[first + 1];
    if (high & 0xffff_0000 != 0) return null;
    const base = @as(u64, low) | (@as(u64, high) << 32);
    const address = if (byte_offset >= 0)
        std.math.add(u64, base, @intCast(byte_offset)) catch return null
    else
        std.math.sub(u64, base, @intCast(-byte_offset)) catch return null;
    if (address == 0) return null;
    var words: [4]u32 = undefined;
    try reader.readWords(address & ~@as(u64, 3), &words);
    return gpu.resources.decodeBufferDescriptor(&words) catch |err| switch (err) {
        error.InvalidDescriptor, error.InvalidFormat => null,
        else => return err,
    };
}

const PackedImageStoreTexel = struct {
    bytes: [16]u8 = @splat(0),
    length: u8,
};

const WholeImageClear = struct {
    descriptor: gpu.ImageDescriptor,
    subresource: gpu.TextureSubresourceLayout,
    texel: PackedImageStoreTexel,
    allocation_bytes: usize,
};

fn planWholeImageClear(
    descriptor: gpu.ImageDescriptor,
    values: [4]u32,
    data_mask: u4,
    dispatched_width: u64,
    dispatched_height: u64,
) ?WholeImageClear {
    if (descriptor.address == 0 or descriptor.dcc_enabled or
        descriptor.cmask_fast_clear or descriptor.fmask_compression or
        descriptor.samplesLog2() != 0 or
        descriptor.viewBaseLevel() != 0 or descriptor.viewMipLevels() != 1 or
        descriptor.image_type != .color_2d)
    {
        return null;
    }
    const texel = packImageStoreTexel(
        descriptor.unified_format,
        values,
        data_mask,
        descriptor.dst_select,
    ) orelse return null;
    const texture = gpu.TextureLayout.fromImage(descriptor) catch return null;
    const subresource = texture.subresource(0, 0, 1) catch return null;
    if (texel.length != subresource.block.bytes_per_element or
        dispatched_width < subresource.width or dispatched_height < subresource.height)
    {
        return null;
    }
    const maximum_clear_bytes: u64 = 256 * 1024 * 1024;
    if (texture.required_source_bytes == 0 or texture.required_source_bytes > maximum_clear_bytes) return null;
    const allocation_bytes = std.math.cast(usize, texture.required_source_bytes) orelse return null;
    return .{
        .descriptor = descriptor,
        .subresource = subresource,
        .texel = texel,
        .allocation_bytes = allocation_bytes,
    };
}

fn unorm8FromFloatBits(bits: u32) u8 {
    const value: f32 = @bitCast(bits);
    if (std.math.isNan(value) or value <= 0.0) return 0;
    if (value >= 1.0) return 255;
    return @intFromFloat(@round(value * 255.0));
}

fn storageImageValues(values: [4]u32, dst_select: [4]u8) [4]u32 {
    var result: [4]u32 = @splat(0);
    for (0..4) |physical_channel| {
        const target: u8 = @intCast(4 + physical_channel);
        for (dst_select, 0..) |selector, shader_channel| {
            if (selector != target) continue;
            result[physical_channel] = values[shader_channel];
            break;
        }
    }
    return result;
}

fn packImageStoreTexel(
    format: u16,
    shader_values: [4]u32,
    data_mask: u4,
    dst_select: [4]u8,
) ?PackedImageStoreTexel {
    const values = storageImageValues(shader_values, dst_select);
    return switch (format) {
        // IMG_DATA_FORMAT_8 / IMG_NUM_FORMAT_UINT
        5 => if (data_mask == 0x1) .{
            .bytes = .{ @intCast(@min(values[0], 255)), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .length = 1,
        } else null,
        // IMG_DATA_FORMAT_16 / IMG_NUM_FORMAT_UINT
        11 => if (data_mask == 0xf) blk: {
            var result = PackedImageStoreTexel{ .length = 2 };
            std.mem.writeInt(u16, result.bytes[0..2], @intCast(@min(values[0], 65535)), .little);
            break :blk result;
        } else null,
        // IMG_DATA_FORMAT_32 / IMG_NUM_FORMAT_UINT
        20 => if (data_mask == 0xf) blk: {
            var result = PackedImageStoreTexel{ .length = 4 };
            std.mem.writeInt(u32, result.bytes[0..4], values[0], .little);
            break :blk result;
        } else null,
        // IMG_DATA_FORMAT_8_8_8_8 / IMG_NUM_FORMAT_UNORM
        56 => if (data_mask == 0xf) .{
            .bytes = .{
                unorm8FromFloatBits(values[0]),
                unorm8FromFloatBits(values[1]),
                unorm8FromFloatBits(values[2]),
                unorm8FromFloatBits(values[3]),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            },
            .length = 4,
        } else null,
        // IMG_DATA_FORMAT_8_8_8_8 / IMG_NUM_FORMAT_UINT
        60 => if (data_mask == 0xf) .{
            .bytes = .{
                @intCast(@min(values[0], 255)),
                @intCast(@min(values[1], 255)),
                @intCast(@min(values[2], 255)),
                @intCast(@min(values[3], 255)),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            },
            .length = 4,
        } else null,
        // IMG_DATA_FORMAT_16_16_16_16 / IMG_NUM_FORMAT_FLOAT
        71 => if (data_mask == 0xf) blk: {
            var result = PackedImageStoreTexel{ .length = 8 };
            for (values, 0..) |bits, channel| {
                const value: f32 = @bitCast(bits);
                const half: f16 = @floatCast(value);
                std.mem.writeInt(u16, result.bytes[channel * 2 ..][0..2], @bitCast(half), .little);
            }
            break :blk result;
        } else null,
        // IMG_DATA_FORMAT_32_32_32_32 / IMG_NUM_FORMAT_FLOAT
        77 => if (data_mask == 0xf) blk: {
            var result = PackedImageStoreTexel{ .length = 16 };
            for (values, 0..) |bits, channel| {
                std.mem.writeInt(u32, result.bytes[channel * 4 ..][0..4], bits, .little);
            }
            break :blk result;
        } else null,
        else => null,
    };
}

fn descriptorFromComputeUserData(state: *const gpu.State, first_register: u32) anyerror!gpu.BufferDescriptor {
    var words: [4]u32 = undefined;
    for (&words, 0..) |*word, index| {
        word.* = state.readRegister(.shader, 0x240 + first_register + @as(u32, @intCast(index))) orelse {
            return Error.MissingStorageDescriptor;
        };
    }
    return gpu.resources.decodeBufferDescriptor(&words);
}

fn readGuestU32(memory: GuestMemory, address: u64) Error!u32 {
    var bytes: [4]u8 = undefined;
    if (!memory.read(memory.context, address, &bytes)) return Error.GuestMemoryReadFailed;
    return std.mem.readInt(u32, &bytes, .little);
}

fn writeGuestU32(memory: GuestMemory, address: u64, value: u32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    if (!memory.write(memory.context, address, &bytes)) return Error.GuestMemoryWriteFailed;
}

fn computeLocalSize(state: *const gpu.State, register: u32) u32 {
    const encoded = state.readRegister(.shader, register) orelse return 1;
    return @max(encoded, 1);
}

const dispatch_initiator_use_thread_dimensions: u32 = 1 << 5;

/// DISPATCH_DIRECT normally carries workgroup counts. With the Gen5
/// USE_THREAD_DIMENSIONS initiator bit set, each dimension instead names the
/// total number of threads and must be rounded up by the programmed local
/// size before it is passed to Vulkan.
fn dispatchGroupCounts(dimensions: [3]u32, local_size: [3]u32, initiator: u32) [3]u32 {
    if (initiator & dispatch_initiator_use_thread_dimensions == 0) return dimensions;

    var result: [3]u32 = undefined;
    for (dimensions, local_size, 0..) |threads, local_raw, index| {
        const local = @max(local_raw, 1);
        result[index] = threads / local + @intFromBool(threads % local != 0);
    }
    return result;
}

fn computeLdsSizeBytes(state: *const gpu.State) u32 {
    const rsrc2 = state.readRegister(.shader, 0x213) orelse return 0;
    const blocks = (rsrc2 >> 15) & 0x1ff;
    return blocks * 512;
}

fn scalarPrefixEnd(analysis: *const gpu.ShaderAnalysis) u32 {
    var end: u32 = 0;
    for (analysis.program.instructions.items) |inst| {
        if (inst.opcode.isBranch() or inst.opcode == .s_setpc_b64) break;
        switch (inst.family) {
            .sop1, .sop2, .sopk, .smem => end = inst.pc + inst.word_count * 4,
            .sopp => switch (inst.opcode) {
                .s_nop, .s_waitcnt, .s_barrier, .s_sleep, .s_sendmsg, .s_ttrace_data, .s_inst_prefetch => {
                    end = inst.pc + inst.word_count * 4;
                },
                else => break,
            },
            else => break,
        }
    }
    return end;
}

fn collectScalarLoadSpecializations(
    scalar: *const gpu.ScalarEvaluation,
    out: []gpu.ShaderSpirvScalarRegister,
) usize {
    var count: usize = 0;
    for (scalar.loadSlice()) |load| {
        for (load.values[0..load.word_count], 0..) |value, word_index| {
            if (count >= out.len) return count;
            out[count] = .{
                .register = load.destination + @as(u32, @intCast(word_index)),
                .value = value,
                .producer_pc = load.pc,
            };
            count += 1;
        }
    }
    return count;
}

fn mergeUserDataScalars(
    bindings: *const gpu.ShaderBindings,
    base: u32,
    out: []gpu.ShaderSpirvScalarRegister,
    count: usize,
) usize {
    var n = count;
    for (bindings.user_data[0..bindings.user_data_count], 0..) |word, index| {
        const reg: u32 = base + @as(u32, @intCast(index));
        if (reg >= 128) break;
        var exists = false;
        for (out[0..n]) |entry| {
            if (entry.register == reg and entry.producer_pc == null) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        if (n >= out.len) break;
        out[n] = .{ .register = reg, .value = word };
        n += 1;
    }
    return n;
}

fn removeScalarRegisterRange(
    registers: []gpu.ShaderSpirvScalarRegister,
    count: usize,
    first: u32,
    width: u32,
) usize {
    const end = @min(first +| width, 128);
    var write: usize = 0;
    for (registers[0..count]) |entry| {
        if (entry.register >= first and entry.register < end) continue;
        registers[write] = entry;
        write += 1;
    }
    return write;
}

fn countNonzeroRgba(linear: []const u8) u32 {
    var nonzero: u32 = 0;
    var i: usize = 0;
    while (i + 3 < linear.len) : (i += 4) {
        if (linear[i] != 0 or linear[i + 1] != 0 or linear[i + 2] != 0 or linear[i + 3] != 0) nonzero += 1;
    }
    return nonzero;
}

fn containsNonzeroByte(bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset + 8 <= bytes.len) : (offset += 8) {
        if (std.mem.readInt(u64, bytes[offset..][0..8], .little) != 0) return true;
    }
    for (bytes[offset..]) |byte| if (byte != 0) return true;
    return false;
}

test "nonzero byte probe covers word chunks and tails" {
    const zeroes = [_]u8{0} ** 17;
    try std.testing.expect(!containsNonzeroByte(&zeroes));

    var word_nonzero = zeroes;
    word_nonzero[9] = 1;
    try std.testing.expect(containsNonzeroByte(&word_nonzero));

    var tail_nonzero = zeroes;
    tail_nonzero[16] = 1;
    try std.testing.expect(containsNonzeroByte(&tail_nonzero));
}

fn hashGuestMemoryRange(memory: GuestMemory, address: u64, span: usize) u64 {
    var hash: u64 = 14695981039346656037;
    if (span == 0) return hash;

    // Hash a distributed set of cache lines rather than only the first few
    // kilobytes. GPU render-target generations cover exact host writes; these
    // probes catch CPU/streaming updates without hashing a multi-megabyte image
    // for every draw.
    const chunk_size: usize = 64;
    const maximum_chunks: usize = 128;
    const target_stride: usize = 64 * 1024;
    const ideal_chunks = 1 + ((span - 1) / target_stride);
    const chunk_count = @min(maximum_chunks, @max(@as(usize, 1), ideal_chunks));
    const readable = @min(chunk_size, span);
    const last_offset = span - readable;
    var index: usize = 0;
    while (index < chunk_count) : (index += 1) {
        var chunk: [chunk_size]u8 = @splat(0);
        const offset = if (chunk_count == 1) 0 else (last_offset * index) / (chunk_count - 1);
        if (!memory.read(memory.context, address + offset, chunk[0..readable])) continue;
        for (chunk[0..readable]) |byte| {
            hash ^= byte;
            hash *%= 1099511628211;
        }
    }
    return hash;
}

fn sampledImageFormat(unified_format: u16, force_srgb: bool) ?u32 {
    return switch (unified_format) {
        1 => vk.format_r8_unorm,
        2 => vk.format_r8_snorm,
        5 => vk.format_r8_uint,
        6 => vk.format_r8_sint,
        14 => vk.format_r8g8_unorm,
        15 => vk.format_r8g8_snorm,
        18 => vk.format_r8g8_uint,
        19 => vk.format_r8g8_sint,
        36 => vk.format_b10g11r11_ufloat_pack32,
        50 => vk.format_a2b10g10r10_unorm_pack32,
        56 => if (force_srgb) vk.format_r8g8b8a8_srgb else vk.format_r8g8b8a8_unorm,
        71 => vk.format_r16g16b16a16_sfloat,
        130 => vk.format_r8g8b8a8_srgb,
        169 => if (force_srgb) vk.format_bc1_rgba_srgb_block else vk.format_bc1_rgba_unorm_block,
        170 => vk.format_bc1_rgba_srgb_block,
        171 => if (force_srgb) vk.format_bc2_srgb_block else vk.format_bc2_unorm_block,
        172 => vk.format_bc2_srgb_block,
        173 => if (force_srgb) vk.format_bc3_srgb_block else vk.format_bc3_unorm_block,
        174 => vk.format_bc3_srgb_block,
        175 => vk.format_bc4_unorm_block,
        176 => vk.format_bc4_snorm_block,
        177 => vk.format_bc5_unorm_block,
        178 => vk.format_bc5_snorm_block,
        179 => vk.format_bc6h_ufloat_block,
        180 => vk.format_bc6h_sfloat_block,
        181 => if (force_srgb) vk.format_bc7_srgb_block else vk.format_bc7_unorm_block,
        182 => vk.format_bc7_srgb_block,
        else => null,
    };
}

const StorageImageFormat = struct {
    spirv: gpu.ShaderSpirvStorageImageFormat,
    vulkan: u32,
};

fn storageImageFormat(unified_format: u16) ?StorageImageFormat {
    return switch (unified_format) {
        5 => .{ .spirv = .r8_uint, .vulkan = vk.format_r8_uint },
        11 => .{ .spirv = .r16_uint, .vulkan = vk.format_r16_uint },
        20 => .{ .spirv = .r32_uint, .vulkan = vk.format_r32_uint },
        36 => .{ .spirv = .r11g11b10_float, .vulkan = vk.format_b10g11r11_ufloat_pack32 },
        56 => .{ .spirv = .rgba8_unorm, .vulkan = vk.format_r8g8b8a8_unorm },
        60 => .{ .spirv = .rgba8_uint, .vulkan = vk.format_r8g8b8a8_uint },
        71 => .{ .spirv = .rgba16_float, .vulkan = vk.format_r16g16b16a16_sfloat },
        77 => .{ .spirv = .rgba32_float, .vulkan = vk.format_r32g32b32a32_sfloat },
        else => null,
    };
}

fn storageImageBytesPerTexel(unified_format: u16) u8 {
    return switch (unified_format) {
        1...6 => 1,
        7...19 => 2,
        20, 36, 50, 56, 60, 130 => 4,
        71 => 8,
        77 => 16,
        169, 170 => 8,
        171...182 => 16,
        else => 0,
    };
}

fn vulkanMinMagFilter(filter: u8) u32 {
    return if (filter == 1 or filter == 3) 1 else 0;
}

fn vulkanAddressMode(mode: u8) Error!u32 {
    return switch (mode) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
        4 => 3,
        5 => 4,
        6 => 3,
        7 => 4,
        else => Error.UnsupportedSampledImage,
    };
}

fn guestSamplerCreateInfo(descriptor: gpu.resources.SamplerDescriptor) Error!vk.SamplerCreateInfo {
    // GFX10 encodes anisotropic point/linear as 2/3. Vulkan keeps
    // anisotropy as a separate setting, so preserve their base point/linear
    // behavior even while anisotropic filtering is off.
    const magnification_filter = vulkanMinMagFilter(descriptor.magnification_filter);
    const unnormalized = descriptor.unnormalized_coordinates;
    return .{
        .magnification_filter = magnification_filter,
        // Vulkan requires equal minification and magnification filters for
        // unnormalized samplers.
        .minification_filter = if (unnormalized)
            magnification_filter
        else
            vulkanMinMagFilter(descriptor.minification_filter),
        .mipmap_mode = if (!unnormalized and descriptor.mip_filter == 2) 1 else 0,
        // Unnormalized coordinates may only use clamp-to-edge/border. Guest
        // lookup textures use clamp-to-edge semantics for all three axes.
        .address_mode_u = if (unnormalized) 2 else try vulkanAddressMode(descriptor.clamp_x),
        .address_mode_v = if (unnormalized) 2 else try vulkanAddressMode(descriptor.clamp_y),
        .address_mode_w = if (unnormalized) 2 else try vulkanAddressMode(descriptor.clamp_z),
        .mip_lod_bias = if (unnormalized) 0 else descriptor.lod_bias,
        .minimum_lod = if (unnormalized) 0 else descriptor.minimum_lod,
        .maximum_lod = if (unnormalized) 0 else descriptor.maximum_lod,
        .unnormalized_coordinates = @intFromBool(unnormalized),
    };
}

fn vulkanComponentSwizzle(selector: u8) Error!u32 {
    return switch (selector) {
        0 => vk.component_swizzle_zero,
        1 => vk.component_swizzle_one,
        4 => vk.component_swizzle_r,
        5 => vk.component_swizzle_g,
        6 => vk.component_swizzle_b,
        7 => vk.component_swizzle_a,
        else => Error.UnsupportedSampledImage,
    };
}

fn sampledImageComponents(selectors: [4]u8) Error!vk.ComponentMapping {
    for (selectors) |selector| {
        if (selector != 0 and selector != 1 and (selector < 4 or selector > 7)) {
            std.debug.print("[vulkan dcb] unsupported sampled component selectors {any}\n", .{selectors});
            return Error.UnsupportedSampledImage;
        }
    }
    return .{
        .r = try vulkanComponentSwizzle(selectors[0]),
        .g = try vulkanComponentSwizzle(selectors[1]),
        .b = try vulkanComponentSwizzle(selectors[2]),
        .a = try vulkanComponentSwizzle(selectors[3]),
    };
}

fn sampledImageStateHash(
    descriptor: gpu.resources.ImageDescriptor,
    sampler: gpu.resources.SamplerDescriptor,
) u64 {
    const words = [_]u32{
        descriptor.unified_format,
        @as(u32, descriptor.dst_select[0]) |
            (@as(u32, descriptor.dst_select[1]) << 8) |
            (@as(u32, descriptor.dst_select[2]) << 16) |
            (@as(u32, descriptor.dst_select[3]) << 24),
        @intFromBool(sampler.force_srgb),
        @as(u32, sampler.clamp_x) |
            (@as(u32, sampler.clamp_y) << 8) |
            (@as(u32, sampler.clamp_z) << 16) |
            (@as(u32, @intFromBool(sampler.unnormalized_coordinates)) << 24),
        @as(u32, sampler.magnification_filter) |
            (@as(u32, sampler.minification_filter) << 8) |
            (@as(u32, sampler.mip_filter) << 16),
        @bitCast(sampler.minimum_lod),
        @bitCast(sampler.maximum_lod),
        @bitCast(sampler.lod_bias),
    };
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&words));
}

fn byteRangesOverlap(a_address: u64, a_size_usize: usize, b_address: u64, b_size: u64) bool {
    if (a_size_usize == 0 or b_size == 0) return false;
    const a_size = std.math.cast(u64, a_size_usize) orelse std.math.maxInt(u64);
    return if (a_address <= b_address)
        b_address - a_address < a_size
    else
        a_address - b_address < b_size;
}

/// The colour a uniform DCC key resolves to, in the RGBA8 order `stage`
/// produces. The comparison codes are the ones GFX9-GFX10 colour blocks write:
/// four fixed clear colours, one "use the clear registers" code, and 0xff for
/// uncompressed data that has to be read from the surface itself.
fn dccClearTexel(code: u8, descriptor: gpu.resources.ColorTarget) ?[4]u8 {
    return switch (code) {
        0x00 => .{ 0, 0, 0, 0 },
        0x40 => .{ 0, 0, 0, 255 },
        0x80 => .{ 255, 255, 255, 0 },
        0xc0 => .{ 255, 255, 255, 255 },
        // CB_COLOR*_CLEAR_WORD0 holds the cleared texel in the surface's own
        // encoding. Only the 8_8_8_8 UNORM standard swap is unpacked here; any
        // other encoding would be a guess, so it keeps the raw path.
        0x20 => clearWordTexel(descriptor),
        else => null,
    };
}

/// Materializes the uniform DCC clear encodings used by supported colour
/// attachments into the surface's native texel representation.
fn colorDccClearTexel(code: u8, descriptor: gpu.resources.ColorTarget) ?DccClearTexel {
    var result = DccClearTexel{ .bytes = @splat(0), .length = 0 };
    switch (descriptor.format) {
        10 => {
            const rgba = dccClearTexel(code, descriptor) orelse return null;
            result.bytes[0..4].* = rgba;
            result.length = 4;
        },
        12 => {
            if (descriptor.number_type != 7) return null;
            result.length = 8;
            if (code == 0x20) {
                std.mem.writeInt(u32, result.bytes[0..4], descriptor.clear_words[0], .little);
                std.mem.writeInt(u32, result.bytes[4..8], descriptor.clear_words[1], .little);
                return result;
            }
            const channels: [4]u16 = switch (code) {
                0x00 => .{ 0x0000, 0x0000, 0x0000, 0x0000 },
                0x40 => .{ 0x0000, 0x0000, 0x0000, 0x3c00 },
                0x80 => .{ 0x3c00, 0x3c00, 0x3c00, 0x0000 },
                0xc0 => .{ 0x3c00, 0x3c00, 0x3c00, 0x3c00 },
                else => return null,
            };
            for (channels, 0..) |channel, index| {
                std.mem.writeInt(u16, result.bytes[index * 2 ..][0..2], channel, .little);
            }
        },
        else => return null,
    }
    return result;
}

fn clearWordTexel(descriptor: gpu.resources.ColorTarget) ?[4]u8 {
    if (descriptor.format != 10 or descriptor.number_type != 0 or descriptor.component_swap != 0) return null;
    const word = descriptor.clear_words[0];
    return .{
        @truncate(word),
        @truncate(word >> 8),
        @truncate(word >> 16),
        @truncate(word >> 24),
    };
}

const CmaskBlockStats = struct {
    clear_blocks: u32 = 0,
    expanded_blocks: u32 = 0,
};

/// CMASK-only fast clears use nibble 0; nibble F says the corresponding base
/// blocks are expanded and can be staged normally. Other values describe
/// coverage/compression states which need FMASK/MSAA support and are rejected.
fn classifyCmaskBlocks(layout: gpu.CmaskLayout, metadata: []const u8) ?CmaskBlockStats {
    var stats = CmaskBlockStats{};
    for (0..layout.layers) |layer_index| {
        var y: u32 = 0;
        while (y < layout.height) : (y += 8) {
            var x: u32 = 0;
            while (x < layout.width) : (x += 8) {
                const value = layout.value(metadata, x, y, @intCast(layer_index)) catch return null;
                switch (value) {
                    0 => stats.clear_blocks +|= 1,
                    0xf => stats.expanded_blocks +|= 1,
                    else => return null,
                }
            }
        }
    }
    return stats;
}

fn classifyHtileBlocks(
    layout: gpu.HtileLayout,
    metadata: []const u8,
    tile_stencil_disabled: bool,
) ?HtileResolveStats {
    var stats = HtileResolveStats{};
    for (0..layout.layers) |layer_index| {
        var y: u32 = 0;
        while (y < layout.height) : (y += gpu.HtileLayout.region_height) {
            var x: u32 = 0;
            while (x < layout.width) : (x += gpu.HtileLayout.region_width) {
                const word = layout.word(metadata, x, y, @intCast(layer_index)) catch return null;
                if (gpu.HtileLayout.fastClearDepth(word, tile_stencil_disabled)) |depth| {
                    if (depth == 0.0)
                        stats.clear_zero_blocks +|= 1
                    else
                        stats.clear_one_blocks +|= 1;
                } else {
                    stats.base_blocks +|= 1;
                }
            }
        }
    }
    return stats;
}

fn applyHtileDepthFastClears(
    htile: gpu.HtileLayout,
    metadata: []const u8,
    target: gpu.resources.DepthTarget,
    depth: gpu.TextureSubresourceLayout,
    allocation: []u8,
) anyerror!void {
    const bytes: usize = switch (target.format) {
        1 => 2,
        3 => 4,
        else => return error.UnsupportedFormat,
    };
    if (depth.block.bytes_per_element != bytes or allocation.len < depth.required_source_bytes) {
        return error.DestinationTooSmall;
    }
    for (0..htile.layers) |layer_index| {
        const layer: u32 = @intCast(layer_index);
        var block_y: u32 = 0;
        while (block_y < htile.height) : (block_y += gpu.HtileLayout.region_height) {
            var block_x: u32 = 0;
            while (block_x < htile.width) : (block_x += gpu.HtileLayout.region_width) {
                const word = try htile.word(metadata, block_x, block_y, layer);
                const clear_depth = gpu.HtileLayout.fastClearDepth(
                    word,
                    target.tile_stencil_disabled,
                ) orelse continue;
                const end_y = @min(block_y + gpu.HtileLayout.region_height, htile.height);
                const end_x = @min(block_x + gpu.HtileLayout.region_width, htile.width);
                var y = block_y;
                while (y < end_y) : (y += 1) {
                    var x = block_x;
                    while (x < end_x) : (x += 1) {
                        for (0..depth.samples()) |sample_index| {
                            const offset = std.math.cast(
                                usize,
                                try depth.sourceByteOffset(x, y, layer, @intCast(sample_index)),
                            ) orelse return error.GuestBufferTooLarge;
                            if (offset > allocation.len or allocation.len - offset < bytes) {
                                return error.GuestBufferTooLarge;
                            }
                            switch (target.format) {
                                1 => std.mem.writeInt(
                                    u16,
                                    allocation[offset..][0..2],
                                    if (clear_depth == 0.0) 0 else std.math.maxInt(u16),
                                    .little,
                                ),
                                3 => std.mem.writeInt(
                                    u32,
                                    allocation[offset..][0..4],
                                    @bitCast(clear_depth),
                                    .little,
                                ),
                                else => unreachable,
                            }
                        }
                    }
                }
            }
        }
    }
}

fn applyHtileStencilFastClears(
    htile: gpu.HtileLayout,
    metadata: []const u8,
    target: gpu.resources.DepthTarget,
    stencil: gpu.TextureSubresourceLayout,
    allocation: []u8,
) anyerror!void {
    if (stencil.block.bytes_per_element != 1 or allocation.len < stencil.required_source_bytes) {
        return error.DestinationTooSmall;
    }
    for (0..htile.layers) |layer_index| {
        const layer: u32 = @intCast(layer_index);
        var block_y: u32 = 0;
        while (block_y < htile.height) : (block_y += gpu.HtileLayout.region_height) {
            var block_x: u32 = 0;
            while (block_x < htile.width) : (block_x += gpu.HtileLayout.region_width) {
                const word = try htile.word(metadata, block_x, block_y, layer);
                if (gpu.HtileLayout.fastClearDepth(word, target.tile_stencil_disabled) == null) continue;
                const end_y = @min(block_y + gpu.HtileLayout.region_height, htile.height);
                const end_x = @min(block_x + gpu.HtileLayout.region_width, htile.width);
                var y = block_y;
                while (y < end_y) : (y += 1) {
                    var x = block_x;
                    while (x < end_x) : (x += 1) {
                        for (0..stencil.samples()) |sample_index| {
                            const offset = std.math.cast(
                                usize,
                                try stencil.sourceByteOffset(x, y, layer, @intCast(sample_index)),
                            ) orelse return error.GuestBufferTooLarge;
                            if (offset >= allocation.len) return error.GuestBufferTooLarge;
                            allocation[offset] = 0;
                        }
                    }
                }
            }
        }
    }
}

fn applyCmaskClearBlocks(
    layout: gpu.CmaskLayout,
    metadata: []const u8,
    linear: []u8,
    texel: [4]u8,
) void {
    const layer_stride = @as(usize, layout.width) * @as(usize, layout.height) * 4;
    std.debug.assert(linear.len >= layer_stride * @as(usize, layout.layers));
    for (0..layout.layers) |layer_index| {
        var block_y: u32 = 0;
        while (block_y < layout.height) : (block_y += 8) {
            var block_x: u32 = 0;
            while (block_x < layout.width) : (block_x += 8) {
                const layer: u32 = @intCast(layer_index);
                const value = layout.value(metadata, block_x, block_y, layer) catch unreachable;
                if (value != 0) continue;
                const end_y = @min(block_y + 8, layout.height);
                const end_x = @min(block_x + 8, layout.width);
                var y = block_y;
                while (y < end_y) : (y += 1) {
                    var x = block_x;
                    while (x < end_x) : (x += 1) {
                        const pixel = layer_index * layer_stride +
                            (@as(usize, y) * @as(usize, layout.width) + @as(usize, x)) * 4;
                        linear[pixel..][0..4].* = texel;
                    }
                }
            }
        }
    }
}

fn fillRgba8(linear: []u8, texel: [4]u8) void {
    var index: usize = 0;
    while (index + 3 < linear.len) : (index += 4) {
        linear[index..][0..4].* = texel;
    }
}

fn fillTexels(linear: []u8, texel: []const u8) void {
    if (texel.len == 0 or linear.len % texel.len != 0) return;
    var index: usize = 0;
    while (index < linear.len) : (index += texel.len) {
        @memcpy(linear[index..][0..texel.len], texel);
    }
}

fn countNonzeroTexels(linear: []const u8, bytes_per_texel: u8) u32 {
    const stride: usize = bytes_per_texel;
    if (stride == 0 or linear.len % stride != 0) return 0;
    var count: u32 = 0;
    var index: usize = 0;
    while (index < linear.len) : (index += stride) {
        for (linear[index..][0..stride]) |byte| {
            if (byte != 0) {
                count +|= 1;
                break;
            }
        }
    }
    return count;
}

fn fillNeutralTextureRgba8(linear: []u8) void {
    // Dark gray — distinguishable from black clear and from white UI fill.
    var i: usize = 0;
    while (i + 3 < linear.len) : (i += 4) {
        linear[i] = 32;
        linear[i + 1] = 32;
        linear[i + 2] = 40;
        linear[i + 3] = 255;
    }
}

const NearbyLinearHit = struct { address: u64, nonzero: u32 };

fn rgbaLooksLikeImage(chunk: []const u8) bool {
    if (chunk.len < 64) return false;
    var nonzero: u32 = 0;
    var unique: u32 = 0;
    var seen: [16]u32 = @splat(0);
    var seen_n: usize = 0;
    var i: usize = 0;
    while (i + 3 < chunk.len) : (i += 4) {
        const r = chunk[i];
        const g = chunk[i + 1];
        const b = chunk[i + 2];
        const a = chunk[i + 3];
        // Reject common poison / control fills.
        if (r == 0xcd and g == 0xcd and b == 0xcd) continue;
        if (r == 0 and g == 0 and b == 0 and a == 0) continue;
        nonzero += 1;
        const key = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        var known = false;
        for (seen[0..seen_n]) |s| {
            if (s == key) {
                known = true;
                break;
            }
        }
        if (!known and seen_n < seen.len) {
            seen[seen_n] = key;
            seen_n += 1;
            unique += 1;
        }
    }
    // Need real variance: not a solid poison block.
    return nonzero >= chunk.len / 16 and unique >= 3;
}

fn scanNearbyLinearRgba(
    memory: anytype,
    descriptor: gpu.resources.ImageDescriptor,
    linear: []u8,
) ?NearbyLinearHit {
    const w = descriptor.width;
    const h = descriptor.height;
    if (w == 0 or h == 0) return null;
    const row = @as(usize, w) * 4;
    const need = row * @as(usize, h);
    if (linear.len < need) return null;
    const meta = descriptor.metadata_address;
    // Search ±2 MiB around the T# base in 4 KiB steps; sample a 256-byte head.
    const radius: i64 = 2 * 1024 * 1024;
    const step: i64 = 4096;
    var best: ?NearbyLinearHit = null;
    var best_score: u32 = 0;
    var delta: i64 = -radius;
    while (delta <= radius) : (delta += step) {
        const addr_i = @as(i64, @bitCast(descriptor.address)) + delta;
        if (addr_i < 0x10000) continue;
        const addr: u64 = @bitCast(addr_i);
        if (meta != 0 and addr + need > meta and addr < meta + 0x20000) continue;
        var head: [256]u8 = undefined;
        if (!memory.read(memory.context, addr, &head)) continue;
        if (!rgbaLooksLikeImage(&head)) continue;
        @memset(linear, 0);
        var y: u32 = 0;
        var ok = true;
        while (y < h) : (y += 1) {
            const src = addr + @as(u64, y) * row;
            const dst = @as(usize, y) * row;
            if (!memory.read(memory.context, src, linear[dst..][0..row])) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        const nz = countNonzeroRgba(linear[0..need]);
        if (nz > best_score and nz > need / 32) {
            best_score = nz;
            best = .{ .address = addr, .nonzero = nz };
            // Good enough — take first high-quality hit near base.
            if (nz > need / 4 and @abs(delta) < 256 * 1024) break;
        }
    }
    if (best) |hit| {
        // Re-read the winner into linear (may have been overwritten by later tries).
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const src = hit.address + @as(u64, y) * row;
            const dst = @as(usize, y) * row;
            _ = memory.read(memory.context, src, linear[dst..][0..row]);
        }
    }
    return best;
}

fn forceDestinationAlphaOne(rgba: []u8) void {
    var i: usize = 0;
    while (i + 3 < rgba.len) : (i += 4) {
        rgba[i + 3] = 255;
    }
}

fn forceColorTargetAlphaOne(linear: []u8, format: ColorTargetFormat) void {
    switch (format.vulkan) {
        vk.format_r8g8b8a8_unorm => forceDestinationAlphaOne(linear),
        vk.format_r16g16b16a16_sfloat => {
            var index: usize = 0;
            while (index + 7 < linear.len) : (index += 8) {
                std.mem.writeInt(u16, linear[index + 6 ..][0..2], 0x3c00, .little);
            }
        },
        else => {},
    }
}

fn makePresentationOpaque(rgba: []u8) void {
    forceDestinationAlphaOne(rgba);
}

/// Ensure s16..s19 (typical Unity PS colour scale from s_buffer_load_dwordx4)
/// are not all zero after specialization. Missing V# eval leaves zeros that
/// wipe the sample through v_mul_f32.
fn ensureIdentityFragmentScale(
    out: []gpu.ShaderSpirvScalarRegister,
    count: usize,
) usize {
    const one_bits: u32 = @bitCast(@as(f32, 1.0));
    var n = count;
    var reg: u32 = 16;
    while (reg < 20) : (reg += 1) {
        var found = false;
        for (out[0..n]) |entry| {
            if (entry.register == reg) {
                found = true;
                break;
            }
        }
        // Only a register the evaluator could not resolve gets the identity.
        // A resolved 0.0 is a real constant: sprite batchers fill solid
        // rectangles with scale 0 and bias the colour in, and rewriting that
        // to 1.0 replaces the fill with the raw atlas.
        if (found) continue;
        if (n >= out.len) break;
        out[n] = .{ .register = reg, .value = one_bits };
        n += 1;
    }
    return n;
}

fn dumpShaderHead(analysis: *const gpu.ShaderAnalysis, limit: usize) void {
    var printed: usize = 0;
    for (analysis.program.instructions.items) |inst| {
        if (printed >= limit) {
            std.debug.print("  ... ({d} more)\n", .{analysis.program.instructions.items.len - printed});
            break;
        }
        if (inst.opcode == .exp) {
            std.debug.print(
                "  pc=0x{x:0>4} exp target={d} en=0x{x} done={any} compr={any} src0={s}:r{d}/0x{x} src1={s}:r{d}/0x{x}\n",
                .{
                    inst.pc,
                    inst.export_target,
                    inst.export_enable,
                    inst.export_done,
                    inst.export_compressed,
                    @tagName(inst.src0.kind),
                    inst.src0.reg,
                    inst.src0.value,
                    @tagName(inst.src1.kind),
                    inst.src1.reg,
                    inst.src1.value,
                },
            );
        } else if (inst.opcode == .buffer_load_format_xyz or
            inst.opcode == .buffer_load_format_xy or
            inst.opcode == .buffer_load_format_xyzw or
            inst.opcode == .s_buffer_load_dwordx4 or
            inst.opcode == .s_buffer_load_dwordx16 or
            inst.opcode == .s_load_dwordx2)
        {
            const resource = if (inst.family == .smem) inst.src0 else inst.src1;
            std.debug.print(
                "  pc=0x{x:0>4} {s} dst={s}:{d} res={s}:{d} idx={s}:{d}\n",
                .{
                    inst.pc,
                    inst.opcode.mnemonic(),
                    @tagName(inst.dst.kind),
                    inst.dst.reg,
                    @tagName(resource.kind),
                    resource.reg,
                    @tagName(inst.src0.kind),
                    inst.src0.reg,
                },
            );
        } else {
            std.debug.print(
                "  pc=0x{x:0>4} word=0x{x:0>8} {s} dst={s}:{d} src0={s}:r{d}/0x{x} src1={s}:r{d}/0x{x} src2={s}:r{d}/0x{x}\n",
                .{
                    inst.pc,
                    inst.word,
                    inst.opcode.mnemonic(),
                    @tagName(inst.dst.kind),
                    inst.dst.reg,
                    @tagName(inst.src0.kind),
                    inst.src0.reg,
                    inst.src0.value,
                    @tagName(inst.src1.kind),
                    inst.src1.reg,
                    inst.src1.value,
                    @tagName(inst.src2.kind),
                    inst.src2.reg,
                    inst.src2.value,
                },
            );
        }
        printed += 1;
    }
}

fn dumpScalarRegisters(registers: []const gpu.ShaderSpirvScalarRegister) void {
    std.debug.print("  scalar seeds ({d}):", .{registers.len});
    for (registers) |entry| std.debug.print(" s{d}=0x{x}", .{ entry.register, entry.value });
    std.debug.print("\n", .{});
}

fn dumpWideScalarLoads(registers: []const gpu.ShaderSpirvScalarRegister) void {
    var reported: [32]u32 = undefined;
    var reported_count: usize = 0;
    for (registers) |entry| {
        const pc = entry.producer_pc orelse continue;
        var words: usize = 0;
        for (registers) |candidate| {
            if (candidate.producer_pc == pc) words += 1;
        }
        if (words == 0) continue;
        var seen = false;
        for (reported[0..reported_count]) |existing| {
            if (existing == pc) {
                seen = true;
                break;
            }
        }
        if (seen or reported_count >= reported.len) continue;
        reported[reported_count] = pc;
        reported_count += 1;
        std.debug.print("  scalar load pc=0x{x} words={d}:", .{ pc, words });
        for (registers) |candidate| {
            if (candidate.producer_pc != pc) continue;
            std.debug.print(
                " s{d}=0x{x}({d:.5})",
                .{ candidate.register, candidate.value, @as(f32, @bitCast(candidate.value)) },
            );
        }
        std.debug.print("\n", .{});
    }
}

const WindowsFileDump = if (builtin.os.tag == .windows) struct {
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const CREATE_ALWAYS: u32 = 2;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const INVALID_HANDLE_VALUE = @as(*anyopaque, @ptrFromInt(std.math.maxInt(usize)));

    extern "kernel32" fn CreateFileA(
        name: [*:0]const u8,
        access: u32,
        share: u32,
        security: ?*anyopaque,
        disposition: u32,
        attributes: u32,
        template: ?*anyopaque,
    ) callconv(.winapi) *anyopaque;
    extern "kernel32" fn WriteFile(
        handle: *anyopaque,
        buffer: [*]const u8,
        to_write: u32,
        written: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
} else struct {};

/// Writes a binary PPM (P6) of an RGBA8 linear frame for offline inspection.
fn dumpFramePpm(path: [*:0]const u8, width: u32, height: u32, rgba: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (rgba.len < needed or width == 0 or height == 0) return;

    const handle = WindowsFileDump.CreateFileA(
        path,
        WindowsFileDump.GENERIC_WRITE,
        0,
        null,
        WindowsFileDump.CREATE_ALWAYS,
        WindowsFileDump.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == WindowsFileDump.INVALID_HANDLE_VALUE) {
        std.debug.print("[vulkan dcb] frame dump open failed: {s}\n", .{path});
        return;
    }
    defer _ = WindowsFileDump.CloseHandle(handle);

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch return;
    var written: u32 = 0;
    if (WindowsFileDump.WriteFile(handle, header.ptr, @intCast(header.len), &written, null) == 0) {
        std.debug.print("[vulkan dcb] frame dump header write failed\n", .{});
        return;
    }
    // PPM is RGB without alpha; strip A while streaming rows.
    const row_bytes = @as(usize, width) * 3;
    const row = std.heap.page_allocator.alloc(u8, row_bytes) catch {
        std.debug.print("[vulkan dcb] frame dump alloc failed\n", .{});
        return;
    };
    defer std.heap.page_allocator.free(row);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_base = @as(usize, y) * @as(usize, width) * 4;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const si = src_base + @as(usize, x) * 4;
            const di = @as(usize, x) * 3;
            row[di] = rgba[si];
            row[di + 1] = rgba[si + 1];
            row[di + 2] = rgba[si + 2];
        }
        written = 0;
        if (WindowsFileDump.WriteFile(handle, row.ptr, @intCast(row.len), &written, null) == 0) {
            std.debug.print("[vulkan dcb] frame dump row write failed at y={d}\n", .{y});
            return;
        }
    }
    std.debug.print("[vulkan dcb] dumped {s} ({d}x{d})\n", .{ path, width, height });
}

/// Converts a linear RGBA16F attachment to an inspectable RGBA8 PPM. This is
/// used only by the targeted draw tracer; a simple Reinhard curve keeps HDR
/// highlights visible without letting a few large values wash out the frame.
fn dumpRgba16FloatFramePpm(path: [*:0]const u8, width: u32, height: u32, rgba16: []const u8) void {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (width == 0 or height == 0 or rgba16.len < pixel_count * 8) return;
    const rgba8 = std.heap.page_allocator.alloc(u8, pixel_count * 4) catch return;
    defer std.heap.page_allocator.free(rgba8);

    for (0..pixel_count) |pixel| {
        for (0..3) |component| {
            const source_offset = pixel * 8 + component * 2;
            const bits = std.mem.readInt(u16, rgba16[source_offset..][0..2], .little);
            const half: f16 = @bitCast(bits);
            var value: f32 = @floatCast(half);
            if (!std.math.isFinite(value) or value <= 0) value = 0;
            const mapped = value / (1.0 + value);
            rgba8[pixel * 4 + component] = @intFromFloat(@round(@min(mapped, 1.0) * 255.0));
        }
        rgba8[pixel * 4 + 3] = 255;
    }
    dumpFramePpm(path, width, height, rgba8);
}

fn resolveSrtImageDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    slot: usize,
) anyerror!?gpu.resources.ImageDescriptor {
    if (slot > std.math.maxInt(u16)) return null;
    const binding = (try bindings.resolve(reader, .read_only_texture, @intCast(slot))) orelse return null;
    return binding.descriptor.read_only_texture;
}

fn resolveSrtSamplerDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    slot: usize,
) anyerror!?gpu.resources.SamplerDescriptor {
    if (slot > std.math.maxInt(u16)) return null;
    const binding = (try bindings.resolve(reader, .sampler, @intCast(slot))) orelse return null;
    return binding.descriptor.sampler;
}

fn graphicsSrtImageSlot(
    mappings: []const gpu.ShaderSpirvSampledImageBinding,
    resource_sgpr: u32,
) usize {
    var slot: usize = 0;
    for (mappings, 0..) |mapping, index| {
        var first_use = true;
        for (mappings[0..index]) |previous| {
            if (previous.resource_sgpr == mapping.resource_sgpr) {
                first_use = false;
                break;
            }
        }
        if (!first_use) continue;
        if (mapping.resource_sgpr == resource_sgpr) return slot;
        slot += 1;
    }
    return slot;
}

fn graphicsSrtSamplerSlot(
    mappings: []const gpu.ShaderSpirvSampledImageBinding,
    sampler_sgpr: u32,
) usize {
    var slot: usize = 0;
    for (mappings, 0..) |mapping, index| {
        var first_use = true;
        for (mappings[0..index]) |previous| {
            if (previous.sampler_sgpr == mapping.sampler_sgpr) {
                first_use = false;
                break;
            }
        }
        if (!first_use) continue;
        if (mapping.sampler_sgpr == sampler_sgpr) return slot;
        slot += 1;
    }
    return slot;
}

fn scalarBufferDescriptor(
    scalar: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
) gpu.resources.Error!?gpu.BufferDescriptor {
    if (resource_sgpr + 4 > gpu.scalar_provenance.maximum_scalar_registers) return null;
    var words: [4]u32 = undefined;
    for (&words, 0..) |*word, index| {
        const value = scalar.registers[resource_sgpr + index];
        if (!value.known) return null;
        word.* = value.value;
    }
    return try gpu.resources.decodeBufferDescriptor(&words);
}

fn scalarImageDescriptor(
    scalar: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
) gpu.resources.Error!?gpu.ImageDescriptor {
    if (resource_sgpr + 8 > gpu.scalar_provenance.maximum_scalar_registers) return null;
    var words: [8]u32 = undefined;
    for (&words, 0..) |*word, index| {
        const value = scalar.registers[resource_sgpr + index];
        if (!value.known) return null;
        word.* = value.value;
    }
    return gpu.resources.decodeImageDescriptor(&words) catch |err| switch (err) {
        error.InvalidDescriptor, error.InvalidFormat => null,
        else => return err,
    };
}

fn scalarSamplerDescriptor(
    scalar: *const gpu.ScalarEvaluation,
    sampler_sgpr: u32,
) gpu.resources.Error!?gpu.resources.SamplerDescriptor {
    if (sampler_sgpr + 4 > gpu.scalar_provenance.maximum_scalar_registers) return null;
    var words: [4]u32 = undefined;
    for (&words, 0..) |*word, index| {
        const value = scalar.registers[sampler_sgpr + index];
        if (!value.known) return null;
        word.* = value.value;
    }
    return try gpu.resources.decodeSamplerDescriptor(&words);
}

fn inlineBufferDescriptorOrNull(
    bindings: *const gpu.ShaderBindings,
    resource_sgpr: u32,
) anyerror!?gpu.BufferDescriptor {
    return bindings.inlineBufferDescriptor(resource_sgpr) catch |err| switch (err) {
        error.InvalidDescriptor, error.InvalidFormat => null,
        else => return err,
    };
}

fn inlineImageDescriptorOrNull(
    bindings: *const gpu.ShaderBindings,
    resource_sgpr: u32,
) anyerror!?gpu.ImageDescriptor {
    return bindings.inlineImageDescriptor(resource_sgpr) catch |err| switch (err) {
        error.InvalidDescriptor, error.InvalidFormat => null,
        else => return err,
    };
}

fn inlineSamplerDescriptorOrNull(
    bindings: *const gpu.ShaderBindings,
    sampler_sgpr: u32,
) anyerror!?gpu.resources.SamplerDescriptor {
    return try bindings.inlineSamplerDescriptor(sampler_sgpr);
}

fn resolveComputeSampledImageDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    analysis: *const gpu.ShaderAnalysis,
    scalar: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
    instruction_pc: u32,
    fallback_slot: usize,
) anyerror!?gpu.ImageDescriptor {
    if (try scalarImageDescriptor(scalar, resource_sgpr)) |descriptor| return descriptor;
    if (try inlineImageDescriptorOrNull(bindings, resource_sgpr)) |descriptor| return descriptor;

    var pointer_sgpr: ?u32 = null;
    for (analysis.program.instructions.items) |inst| {
        if (inst.pc >= instruction_pc) break;
        if (inst.opcode != .s_load_dwordx8 or inst.dst.kind != .sgpr or
            inst.dst.reg != resource_sgpr or inst.src0.kind != .sgpr) continue;
        pointer_sgpr = inst.src0.reg;
    }
    if (pointer_sgpr) |pointer| {
        if (try imageDescriptorFromUserDataPointer(bindings, reader, pointer)) |descriptor| {
            return descriptor;
        }
    }
    if (fallback_slot <= std.math.maxInt(u16)) {
        if (try bindings.resolve(reader, .read_only_texture, @intCast(fallback_slot))) |binding| {
            return binding.descriptor.read_only_texture;
        }
    }
    return null;
}

fn resolveComputeSamplerDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    analysis: *const gpu.ShaderAnalysis,
    scalar: *const gpu.ScalarEvaluation,
    sampler_sgpr: u32,
    instruction_pc: u32,
    fallback_slot: usize,
) anyerror!?gpu.resources.SamplerDescriptor {
    if (try scalarSamplerDescriptor(scalar, sampler_sgpr)) |descriptor| return descriptor;
    if (try inlineSamplerDescriptorOrNull(bindings, sampler_sgpr)) |descriptor| return descriptor;

    var pointer_sgpr: ?u32 = null;
    for (analysis.program.instructions.items) |inst| {
        if (inst.pc >= instruction_pc) break;
        if (inst.opcode != .s_load_dwordx4 or inst.dst.kind != .sgpr or
            inst.dst.reg != sampler_sgpr or inst.src0.kind != .sgpr) continue;
        pointer_sgpr = inst.src0.reg;
    }
    if (pointer_sgpr) |pointer| {
        if (try samplerDescriptorFromUserDataPointer(bindings, reader, pointer)) |descriptor| {
            return descriptor;
        }
    }
    if (fallback_slot <= std.math.maxInt(u16)) {
        if (try bindings.resolve(reader, .sampler, @intCast(fallback_slot))) |binding| {
            return binding.descriptor.sampler;
        }
    }
    return null;
}

fn resolveComputeImageDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    analysis: *const gpu.ShaderAnalysis,
    scalar: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
    fallback_slot: usize,
) anyerror!?gpu.ImageDescriptor {
    if (try scalarImageDescriptor(scalar, resource_sgpr)) |descriptor| return descriptor;
    if (try inlineImageDescriptorOrNull(bindings, resource_sgpr)) |descriptor| return descriptor;

    // A common AGC compute prolog loads a destination T# from a pointer held
    // directly in USER_DATA after an EXECZ bounds check. Scalar prefix
    // specialization deliberately ends at that branch, so recover the exact
    // s_load_dwordx8 producer rather than leaving the later image_store
    // unbound.
    for (analysis.program.instructions.items) |inst| {
        if (inst.opcode != .s_load_dwordx8 or inst.dst.kind != .sgpr or
            inst.dst.reg != resource_sgpr or inst.src0.kind != .sgpr) continue;
        if (try imageDescriptorFromUserDataPointer(bindings, reader, inst.src0.reg)) |descriptor| {
            return descriptor;
        }
    }
    if (fallback_slot <= std.math.maxInt(u16)) {
        if (try bindings.resolve(reader, .read_write_texture, @intCast(fallback_slot))) |binding| {
            return binding.descriptor.read_write_texture;
        }
    }
    return null;
}

/// Whether a decoded V# can be staged as guest storage.
///
/// USER_DATA often starts with an SRT pointer whose low dword is a small
/// integer. Treating those four words as a V# produces addresses like `0x4`
/// with a large synthetic size — which then fails as `GuestMemoryReadFailed`.
/// Real resource V#s live in mapped direct/flexible memory well above the
/// first pages of the guest address space.
fn isPlausibleBufferDescriptor(descriptor: gpu.BufferDescriptor) bool {
    if (descriptor.isNull()) return false;
    if (descriptor.address < 0x1_0000) return false;
    if (descriptor.size_bytes == 0) return false;
    if (descriptor.size_bytes > maximum_staged_buffer_bytes) return false;
    return true;
}

/// An explicit SMEM producer is stronger evidence than an arbitrary four-word
/// USER_DATA window. Keep its range checks, but allow low addresses used by
/// synthetic heaps and small guest mappings.
fn isBoundedProducedBufferDescriptor(descriptor: gpu.BufferDescriptor) bool {
    if (descriptor.isNull() or descriptor.size_bytes == 0) return false;
    return descriptor.size_bytes <= maximum_staged_buffer_bytes;
}

fn takePlausibleBufferDescriptor(descriptor: ?gpu.BufferDescriptor) ?gpu.BufferDescriptor {
    const value = descriptor orelse return null;
    return if (isPlausibleBufferDescriptor(value)) value else null;
}

fn isPointerScalarLoad(opcode: gpu.ShaderOpcode) bool {
    return switch (opcode) {
        .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16 => true,
        else => false,
    };
}

fn isBufferScalarLoad(opcode: gpu.ShaderOpcode) bool {
    return switch (opcode) {
        .s_buffer_load_dword,
        .s_buffer_load_dwordx2,
        .s_buffer_load_dwordx4,
        .s_buffer_load_dwordx8,
        .s_buffer_load_dwordx16,
        => true,
        else => false,
    };
}

fn scalarMemoryOffset(inst: gpu.ShaderInstruction, scalar: *const gpu.ScalarEvaluation) ?i64 {
    const operand_offset: i64 = switch (inst.src1.kind) {
        .null => 0,
        .integer_inline_constant, .literal_constant => inst.src1.value,
        .sgpr => if (inst.src1.reg < gpu.scalar_provenance.maximum_scalar_registers and
            scalar.registers[inst.src1.reg].known)
            scalar.registers[inst.src1.reg].value
        else
            return null,
        else => return null,
    };
    return @as(i64, inst.memory_offset) + operand_offset;
}

fn decodeBufferDescriptorAt(reader: gpu.ShaderMemoryReader, address: u64) anyerror!?gpu.BufferDescriptor {
    var words: [4]u32 = undefined;
    try reader.readWords(address & ~@as(u64, 3), &words);
    return gpu.resources.decodeBufferDescriptor(&words) catch |err| switch (err) {
        error.InvalidDescriptor, error.InvalidFormat => null,
        else => return err,
    };
}

/// Finds the last scalar-memory producer of a V# before one memory operation.
/// Besides direct `s_load_dwordxN` table reads this follows descriptor-buffer
/// chains (`s_buffer_load_dwordxN`) recursively. This is the common layout of
/// large AGC compute prologs after an EXEC bounds branch.
fn resolveProducedBufferDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    analysis: *const gpu.ShaderAnalysis,
    scalar: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
    before_pc: u32,
    depth: u8,
) anyerror!?gpu.BufferDescriptor {
    if (depth >= 8) return null;
    var index = analysis.program.instructions.items.len;
    while (index != 0) {
        index -= 1;
        const inst = analysis.program.instructions.items[index];
        if (inst.pc >= before_pc or inst.dst.kind != .sgpr or inst.src0.kind != .sgpr) continue;
        if (!isPointerScalarLoad(inst.opcode) and !isBufferScalarLoad(inst.opcode)) continue;
        if (resource_sgpr < inst.dst.reg) continue;
        const word_delta = resource_sgpr - inst.dst.reg;
        if (word_delta + 4 > inst.data_words) continue;
        const base_offset = scalarMemoryOffset(inst, scalar) orelse continue;
        const byte_offset = base_offset + @as(i64, word_delta) * 4;

        if (isPointerScalarLoad(inst.opcode)) {
            if (byte_offset < std.math.minInt(i32) or byte_offset > std.math.maxInt(i32)) continue;
            if (try bufferDescriptorFromUserDataPointer(
                bindings,
                reader,
                inst.src0.reg,
                @intCast(byte_offset),
            )) |descriptor| return descriptor;
            continue;
        }

        const parent = (try inlineBufferDescriptorOrNull(bindings, inst.src0.reg)) orelse
            (try resolveProducedBufferDescriptor(
                bindings,
                reader,
                analysis,
                scalar,
                inst.src0.reg,
                inst.pc,
                depth + 1,
            )) orelse continue;
        if (!isPlausibleBufferDescriptor(parent) or byte_offset < 0) continue;
        const address = std.math.add(u64, parent.address, @intCast(byte_offset)) catch continue;
        if (try decodeBufferDescriptorAt(reader, address)) |descriptor| return descriptor;
    }
    return null;
}

/// Recovers a V# for a compute/graphics MUBUF/SMEM instruction.
///
/// Order of attempts:
/// 1. The last scalar-memory producer before this instruction. Shader inputs
///    are frequently reused as dimensions before an `s_buffer_load` overwrites
///    the same SGPRs with the real V#; decoding the entry snapshot first can
///    therefore produce a syntactically valid but completely unrelated V#.
/// 2. Specialized and full scalar state.
/// 3. V# already resident in USER_DATA.
fn resolveComputeBufferDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    analysis: *const gpu.ShaderAnalysis,
    specialized: *const gpu.ScalarEvaluation,
    full: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
    instruction_pc: u32,
) anyerror!?gpu.BufferDescriptor {
    // `specialized` is the scalar state immediately before this memory
    // instruction. It is stronger than a producer-chain reconstruction and
    // preserves SGPR reuse across several descriptor loads.
    if (takePlausibleBufferDescriptor(try scalarBufferDescriptor(specialized, resource_sgpr))) |descriptor| {
        return descriptor;
    }
    if (try resolveProducedBufferDescriptor(
        bindings,
        reader,
        analysis,
        full,
        resource_sgpr,
        instruction_pc,
        0,
    )) |descriptor| {
        if (isBoundedProducedBufferDescriptor(descriptor)) return descriptor;
    }
    if (takePlausibleBufferDescriptor(try scalarBufferDescriptor(full, resource_sgpr))) |descriptor| {
        return descriptor;
    }
    if (takePlausibleBufferDescriptor(try inlineBufferDescriptorOrNull(bindings, resource_sgpr))) |descriptor| {
        return descriptor;
    }
    // Absolute USER_DATA window only when the shader names an SGPR that sits
    // inside the USER_DATA capture (not below scalar_user_data_base). For
    // export_shader base=8, s4 is a system slot — do not mis-decode UD[4].
    if (resource_sgpr >= bindings.scalar_user_data_base) {
        const first = resource_sgpr - bindings.scalar_user_data_base;
        if (first + 4 <= bindings.user_data_count) {
            if (takePlausibleBufferDescriptor(try gpu.resources.decodeBufferDescriptor(
                bindings.user_data[first..][0..4],
            ))) |descriptor| {
                return descriptor;
            }
        }
    }
    return null;
}

/// Injects AGC vertex-buffer V#s into specialized scalar registers so the
/// SPIR-V translator sees s4:s7 (etc.) as constants and prepareComputeResources
/// can stage the underlying guest memory.
fn seedVertexBufferScalars(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    analysis: *const gpu.ShaderAnalysis,
    out: []gpu.ShaderSpirvScalarRegister,
    count: usize,
    evaluation: ?*gpu.ScalarEvaluation,
) usize {
    if (log_verbose_gpu) std.debug.print(
        "[vulkan dcb] vertex seed: stage={s} header={any} srt={any} ud_base={d} ud_count={d} scalar_s4={any}\n",
        .{
            @tagName(bindings.stage),
            bindings.metadata != null,
            bindings.srt_address != null,
            bindings.scalar_user_data_base,
            bindings.user_data_count,
            if (evaluation) |e| e.registers[4].known else false,
        },
    );
    const vertex = (gpu.VertexBindings.capture(bindings, reader) catch |err| {
        std.debug.print("[vulkan dcb] VertexBindings.capture failed: {s}\n", .{@errorName(err)});
        return count;
    }) orelse {
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] VertexBindings: no attr/buffer tables (fetch={any})\n",
            .{bindings.direct_pointers.fetch_shader != null},
        );
        return count;
    };
    if (vertex.attribute_count == 0) return count;

    // Collect unique resource SGPRs referenced by MUBUF loads, in program order.
    var resource_sgprs: [16]u32 = undefined;
    var resource_count: usize = 0;
    for (analysis.program.instructions.items) |inst| {
        const is_load = switch (inst.opcode) {
            .buffer_load_ubyte,
            .buffer_load_sbyte,
            .buffer_load_ushort,
            .buffer_load_sshort,
            .buffer_load_dword,
            .buffer_load_dwordx2,
            .buffer_load_dwordx3,
            .buffer_load_dwordx4,
            .buffer_load_format_x,
            .buffer_load_format_xy,
            .buffer_load_format_xyz,
            .buffer_load_format_xyzw,
            => true,
            else => false,
        };
        if (!is_load or inst.src1.kind != .sgpr) continue;
        const sgpr = inst.src1.reg;
        var seen = false;
        for (resource_sgprs[0..resource_count]) |existing| {
            if (existing == sgpr) {
                seen = true;
                break;
            }
        }
        if (seen or resource_count >= resource_sgprs.len) continue;
        resource_sgprs[resource_count] = sgpr;
        resource_count += 1;
    }
    if (resource_count == 0) return count;

    // Unique attribute buffers in location order.
    var buffers: [16]gpu.BufferDescriptor = undefined;
    var buffer_words: [16][4]u32 = undefined;
    var buffer_count: usize = 0;
    for (vertex.slice()) |attr| {
        if (!isPlausibleBufferDescriptor(attr.buffer)) continue;
        var dupe = false;
        for (buffers[0..buffer_count]) |existing| {
            if (existing.address == attr.buffer.address) {
                dupe = true;
                break;
            }
        }
        if (dupe or buffer_count >= buffers.len) continue;
        var words: [4]u32 = undefined;
        reader.read(attr.descriptor_address, std.mem.asBytes(&words)) catch continue;
        const decoded = gpu.resources.decodeBufferDescriptor(&words) catch continue;
        if (!isPlausibleBufferDescriptor(decoded)) continue;
        buffers[buffer_count] = decoded;
        buffer_words[buffer_count] = words;
        buffer_count += 1;
    }
    if (buffer_count == 0) {
        std.debug.print(
            "[vulkan dcb] VertexBindings: {d} attrs but no plausible buffers\n",
            .{vertex.attribute_count},
        );
        return count;
    }

    var n = count;
    const pairs = @min(resource_count, buffer_count);
    var pair: usize = 0;
    while (pair < pairs) : (pair += 1) {
        const sgpr = resource_sgprs[pair];
        const words = buffer_words[pair];
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] seed V# s{d}:s{d} addr=0x{x} size=0x{x} stride={d} records={d}\n",
            .{
                sgpr,
                sgpr + 3,
                buffers[pair].address,
                buffers[pair].size_bytes,
                buffers[pair].stride,
                buffers[pair].record_count,
            },
        );
        var word_i: u32 = 0;
        while (word_i < 4) : (word_i += 1) {
            const reg = sgpr + word_i;
            var found: ?usize = null;
            for (out[0..n], 0..) |entry, index| {
                if (entry.register == reg and entry.producer_pc == null) {
                    found = index;
                    break;
                }
            }
            if (found) |index| {
                out[index].value = words[word_i];
            } else if (n < out.len) {
                out[n] = .{ .register = reg, .value = words[word_i] };
                n += 1;
            }
            if (evaluation) |eval| {
                if (reg < eval.registers.len) {
                    eval.registers[reg] = .{
                        .known = true,
                        .value = words[word_i],
                        .sources = .{},
                        .producer_pc = 0,
                    };
                }
            }
        }
    }
    return n;
}

fn layerAvailable(enumerate: vk.PfnEnumerateInstanceLayerProperties, wanted: []const u8) bool {
    var count: u32 = 0;
    if (enumerate(&count, null) != vk.success or count == 0 or count > 64) return false;
    var properties: [64]vk.LayerProperties = undefined;
    if (enumerate(&count, &properties) != vk.success) return false;
    for (properties[0..count]) |property| {
        const length = std.mem.indexOfScalar(u8, &property.layer_name, 0) orelse property.layer_name.len;
        if (std.mem.eql(u8, property.layer_name[0..length], wanted)) return true;
    }
    return false;
}

fn scalePresentedFrame(
    output: []u8,
    output_width_u32: u32,
    output_height_u32: u32,
    output_format: u32,
    frame: PresentedFrame,
) void {
    @memset(output, 0);
    const output_width: usize = output_width_u32;
    const output_height: usize = output_height_u32;
    const source_width: usize = frame.width;
    const source_height: usize = frame.height;
    const source_pitch: usize = frame.row_pitch_bytes;
    var draw_width = output_width;
    var draw_height = output_height;
    if (@as(u64, output_width_u32) * frame.height <= @as(u64, output_height_u32) * frame.width) {
        draw_height = @max(@as(usize, 1), output_width * source_height / source_width);
    } else {
        draw_width = @max(@as(usize, 1), output_height * source_width / source_height);
    }
    const offset_x = (output_width - draw_width) / 2;
    const offset_y = (output_height - draw_height) / 2;
    const swap_red_blue = output_format == vk.format_b8g8r8a8_unorm;
    for (0..draw_height) |y| {
        const source_y = @min(y * source_height / draw_height, source_height - 1);
        for (0..draw_width) |x| {
            const source_x = @min(x * source_width / draw_width, source_width - 1);
            const source = source_y * source_pitch + source_x * 4;
            const destination = ((offset_y + y) * output_width + offset_x + x) * 4;
            if (swap_red_blue) {
                output[destination] = frame.pixels[source + 2];
                output[destination + 1] = frame.pixels[source + 1];
                output[destination + 2] = frame.pixels[source];
            } else {
                output[destination] = frame.pixels[source];
                output[destination + 1] = frame.pixels[source + 1];
                output[destination + 2] = frame.pixels[source + 2];
            }
            output[destination + 3] = frame.pixels[source + 3];
        }
    }
}

fn choosePhysicalDevice(
    allocator: std.mem.Allocator,
    instance_handle: vk.Instance,
    functions: *const InstanceFunctions,
    surface: vk.Surface,
    surface_functions: ?*const SurfaceFunctions,
) (Error || std.mem.Allocator.Error)!Candidate {
    var count: u32 = 0;
    if (functions.enumerate_physical_devices(instance_handle, &count, null) != vk.success or count == 0) {
        return Error.NoPhysicalDevice;
    }
    const devices = try allocator.alloc(vk.PhysicalDevice, count);
    defer allocator.free(devices);
    if (functions.enumerate_physical_devices(instance_handle, &count, devices.ptr) != vk.success) {
        return Error.NoPhysicalDevice;
    }

    var best: ?Candidate = null;
    for (devices[0..count]) |physical_device| {
        var raw_properties: [4096]u8 align(8) = undefined;
        functions.get_physical_device_properties(physical_device, @ptrCast(&raw_properties));
        const api_version = std.mem.readInt(u32, raw_properties[0..4], .little);
        if (api_version < vk.api_version_1_2) continue;

        var family_count: u32 = 0;
        functions.get_queue_family_properties(physical_device, &family_count, null);
        if (family_count == 0) continue;
        const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
        defer allocator.free(families);
        functions.get_queue_family_properties(physical_device, &family_count, families.ptr);

        var selected_family: ?u32 = null;
        for (families[0..family_count], 0..) |family, index| {
            if (family.queue_count == 0 or family.queue_flags & vk.required_queue_flags != vk.required_queue_flags) continue;
            if (surface != 0) {
                var supported: vk.Bool32 = 0;
                const query = surface_functions orelse continue;
                if (query.get_surface_support(physical_device, @intCast(index), surface, &supported) != vk.success or
                    supported == 0) continue;
            }
            selected_family = @intCast(index);
            break;
        }
        const family_index = selected_family orelse continue;

        const device_type = std.mem.readInt(u32, raw_properties[16..20], .little);
        const name_source = raw_properties[20..276];
        const name_length = std.mem.indexOfScalar(u8, name_source, 0) orelse name_source.len;
        var info = DeviceInfo{
            .api_version = api_version,
            .vendor_id = std.mem.readInt(u32, raw_properties[8..12], .little),
            .device_id = std.mem.readInt(u32, raw_properties[12..16], .little),
            .device_type = device_type,
        };
        @memcpy(info.name_bytes[0..name_length], name_source[0..name_length]);
        info.name_length = @intCast(name_length);
        const score: u32 = switch (device_type) {
            vk.physical_device_type_discrete_gpu => 300,
            vk.physical_device_type_integrated_gpu => 200,
            else => 100,
        };
        if (best == null or score > best.?.score) {
            best = .{
                .physical_device = physical_device,
                .queue_family_index = family_index,
                .info = info,
                .score = score,
            };
        }
    }
    return best orelse Error.NoCompatiblePhysicalDevice;
}

fn findMemoryTypeIn(properties: vk.PhysicalDeviceMemoryProperties, supported_bits: u32, required: vk.Flags) ?u32 {
    var index: u32 = 0;
    while (index < properties.memory_type_count and index < 32) : (index += 1) {
        const bit = @as(u32, 1) << @intCast(index);
        const flags = properties.memory_types[index].property_flags;
        if (supported_bits & bit != 0 and flags & required == required) return index;
    }
    return null;
}

fn createWindowPresentation(
    allocator: std.mem.Allocator,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    device_functions: *const DeviceFunctions,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    native_window: NativeWindow,
    surface: vk.Surface,
    surface_functions: SurfaceFunctions,
    swapchain_functions: SwapchainFunctions,
) (Error || std.mem.Allocator.Error)!WindowPresentation {
    var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    if (surface_functions.get_surface_capabilities(physical_device, surface, &capabilities) != vk.success) {
        return Error.SurfaceQueryFailed;
    }
    if (capabilities.supported_usage_flags & vk.image_usage_transfer_dst_bit == 0) {
        return Error.SurfaceFormatUnavailable;
    }

    var format_count: u32 = 0;
    if (surface_functions.get_surface_formats(physical_device, surface, &format_count, null) != vk.success or
        format_count == 0 or format_count > 256)
    {
        return Error.SurfaceQueryFailed;
    }
    const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    defer allocator.free(formats);
    if (surface_functions.get_surface_formats(physical_device, surface, &format_count, formats.ptr) != vk.success) {
        return Error.SurfaceQueryFailed;
    }
    var selected: ?vk.SurfaceFormatKHR = null;
    for (formats[0..format_count]) |format| {
        if (format.format == vk.format_r8g8b8a8_unorm and format.color_space == vk.color_space_srgb_nonlinear_khr) {
            selected = format;
            break;
        }
        if (selected == null and format.format == vk.format_b8g8r8a8_unorm and
            format.color_space == vk.color_space_srgb_nonlinear_khr)
        {
            selected = format;
        }
    }
    const surface_format = selected orelse return Error.SurfaceFormatUnavailable;
    const variable_extent = capabilities.current_extent.width == std.math.maxInt(u32);
    const extent = if (variable_extent)
        vk.Extent2D{
            .width = std.math.clamp(native_window.width, capabilities.minimum_image_extent.width, capabilities.maximum_image_extent.width),
            .height = std.math.clamp(native_window.height, capabilities.minimum_image_extent.height, capabilities.maximum_image_extent.height),
        }
    else
        capabilities.current_extent;
    if (extent.width == 0 or extent.height == 0) return Error.SurfaceFormatUnavailable;
    var image_count = capabilities.minimum_image_count + 1;
    if (capabilities.maximum_image_count != 0) image_count = @min(image_count, capabilities.maximum_image_count);
    const composite_alpha = if (capabilities.supported_composite_alpha & vk.composite_alpha_opaque_bit_khr != 0)
        vk.composite_alpha_opaque_bit_khr
    else
        capabilities.supported_composite_alpha & (~capabilities.supported_composite_alpha +% 1);
    if (composite_alpha == 0) return Error.SurfaceFormatUnavailable;

    const create_info = vk.SwapchainCreateInfoKHR{
        .surface = surface,
        .minimum_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_usage = vk.image_usage_transfer_dst_bit,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = composite_alpha,
        .present_mode = vk.present_mode_fifo_khr,
    };
    var swapchain: vk.Swapchain = 0;
    if (swapchain_functions.create_swapchain(device, &create_info, null, &swapchain) != vk.success) {
        return Error.SwapchainCreationFailed;
    }
    errdefer swapchain_functions.destroy_swapchain(device, swapchain, null);
    var swapchain_image_count: u32 = 0;
    if (swapchain_functions.get_swapchain_images(device, swapchain, &swapchain_image_count, null) != vk.success or
        swapchain_image_count == 0)
    {
        return Error.SwapchainImageQueryFailed;
    }
    const images = try allocator.alloc(vk.Image, swapchain_image_count);
    errdefer allocator.free(images);
    if (swapchain_functions.get_swapchain_images(device, swapchain, &swapchain_image_count, images.ptr) != vk.success) {
        return Error.SwapchainImageQueryFailed;
    }
    // One persistent upload buffer and acquire fence serve every present, so
    // a flip no longer allocates Vulkan objects or blocks waiting for the
    // swapchain. The extent is fixed at swapchain creation (FIFO mode), so the
    // buffer never needs to grow.
    const output_bytes = @as(vk.DeviceSize, extent.width) * extent.height * 4;
    const upload_info = vk.BufferCreateInfo{
        .size = output_bytes,
        .usage = vk.buffer_usage_transfer_src_bit,
    };
    var upload_handle: vk.Buffer = 0;
    if (device_functions.create_buffer(device, &upload_info, null, &upload_handle) != vk.success) {
        return Error.BufferCreationFailed;
    }
    errdefer device_functions.destroy_buffer(device, upload_handle, null);
    var upload_requirements: vk.MemoryRequirements = undefined;
    device_functions.get_buffer_memory_requirements(device, upload_handle, &upload_requirements);
    const upload_memory_type = findMemoryTypeIn(
        memory_properties,
        upload_requirements.memory_type_bits,
        vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
    ) orelse return Error.NoCompatibleMemoryType;
    const upload_allocation = vk.MemoryAllocateInfo{
        .allocation_size = upload_requirements.size,
        .memory_type_index = upload_memory_type,
    };
    var upload_memory: vk.DeviceMemory = 0;
    if (device_functions.allocate_memory(device, &upload_allocation, null, &upload_memory) != vk.success) {
        return Error.MemoryAllocationFailed;
    }
    errdefer device_functions.free_memory(device, upload_memory, null);
    if (device_functions.bind_buffer_memory(device, upload_handle, upload_memory, 0) != vk.success) {
        return Error.MemoryBindingFailed;
    }
    const acquire_fence_info = vk.FenceCreateInfo{};
    var acquire_fence: vk.Fence = 0;
    if (device_functions.create_fence(device, &acquire_fence_info, null, &acquire_fence) != vk.success) {
        return Error.FenceCreationFailed;
    }
    errdefer device_functions.destroy_fence(device, acquire_fence, null);
    return .{
        .native_window = native_window,
        .surface_functions = surface_functions,
        .swapchain_functions = swapchain_functions,
        .surface = surface,
        .swapchain = swapchain,
        .images = images,
        .extent = extent,
        .format = surface_format.format,
        .upload = .{ .handle = upload_handle, .memory = upload_memory, .size = output_bytes },
        .acquire_fence = acquire_fence,
    };
}

fn buildParameterProbeFragmentSpirv(allocator: std.mem.Allocator) !rdna2.spirv.Module {
    const vgpr = struct {
        fn at(reg: u32) rdna2.Operand {
            return .{ .kind = .vgpr, .reg = reg };
        }
    }.at;
    const uint = struct {
        fn value(bits: u32) rdna2.Operand {
            return .{ .kind = .integer_inline_constant, .value = bits, .signed_val = @intCast(bits) };
        }
    }.value;

    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(allocator);
    for (0..4) |component| {
        const channel: u32 = @intCast(component);
        try program.instructions.append(allocator, .{
            .pc = channel * 4,
            .family = .vintrp,
            .opcode = .v_interp_mov_f32,
            .dst = vgpr(channel),
            .src0 = uint(channel),
            .src1 = uint(0),
            .src2 = uint(channel),
            .src_count = 3,
        });
    }
    try program.instructions.appendSlice(allocator, &.{
        .{ .pc = 16, .family = .exp, .opcode = .exp, .export_target = 0, .export_enable = 0xf, .export_done = true, .src0 = vgpr(0), .src1 = vgpr(1), .src2 = vgpr(2), .src3 = vgpr(3), .src_count = 4 },
        .{ .pc = 24, .family = .sopp, .opcode = .s_endpgm },
    });
    return rdna2.translateSpirv(allocator, &program, .{
        .stage = .fragment,
        .parameter_mask = 1,
        .infer_fragment_parameter_mask = false,
    });
}

fn buildTextureProbeFragmentSpirv(
    allocator: std.mem.Allocator,
    binding: rdna2.spirv.SampledImageBinding,
    fragment_extent: [2]u32,
) !rdna2.spirv.Module {
    const vgpr = struct {
        fn at(reg: u32) rdna2.Operand {
            return .{ .kind = .vgpr, .reg = reg };
        }
    }.at;
    const sgpr = struct {
        fn at(reg: u32) rdna2.Operand {
            return .{ .kind = .sgpr, .reg = reg };
        }
    }.at;
    const uint = struct {
        fn value(bits: u32) rdna2.Operand {
            return .{ .kind = .integer_inline_constant, .value = bits, .signed_val = @intCast(bits) };
        }
    }.value;
    const sample_pc = binding.instruction_pc orelse 8;

    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(allocator);
    try program.instructions.appendSlice(allocator, &.{
        // The traced Unity UI shader samples from PARAM1.xy. PARAM0 carries
        // the per-vertex colour and is intentionally not involved here.
        .{ .pc = 0, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(0), .src0 = uint(0), .src1 = uint(1), .src2 = uint(0), .src_count = 3 },
        .{ .pc = 4, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(1), .src0 = uint(1), .src1 = uint(1), .src2 = uint(1), .src_count = 3 },
        .{
            .pc = sample_pc,
            .family = .mimg,
            .opcode_id = 0x20,
            .opcode = .image_sample,
            .dst = vgpr(2),
            .src0 = vgpr(0),
            .src1 = sgpr(binding.resource_sgpr),
            .src2 = sgpr(binding.sampler_sgpr),
            .src_count = 3,
            .data_mask = 0xf,
            .image_dimension = .dim_2d,
            .image_address_components = 2,
        },
        .{ .pc = sample_pc + 8, .family = .exp, .opcode = .exp, .export_target = 0, .export_enable = 0xf, .export_done = true, .src0 = vgpr(2), .src1 = vgpr(3), .src2 = vgpr(4), .src3 = vgpr(5), .src_count = 4 },
        .{ .pc = sample_pc + 16, .family = .sopp, .opcode = .s_endpgm },
    });
    const sampled = [_]rdna2.spirv.SampledImageBinding{binding};
    return rdna2.translateSpirv(allocator, &program, .{
        .stage = .fragment,
        .fragment_extent = fragment_extent,
        .sampled_images = &sampled,
        .parameter_mask = 2,
        .infer_fragment_parameter_mask = false,
    });
}

fn buildUiProbeFragmentSpirv(
    allocator: std.mem.Allocator,
    binding: rdna2.spirv.SampledImageBinding,
    fragment_extent: [2]u32,
) !rdna2.spirv.Module {
    const vgpr = struct {
        fn at(reg: u32) rdna2.Operand {
            return .{ .kind = .vgpr, .reg = reg };
        }
    }.at;
    const sgpr = struct {
        fn at(reg: u32) rdna2.Operand {
            return .{ .kind = .sgpr, .reg = reg };
        }
    }.at;
    const uint = struct {
        fn value(bits: u32) rdna2.Operand {
            return .{ .kind = .integer_inline_constant, .value = bits, .signed_val = @intCast(bits) };
        }
    }.value;
    const float = struct {
        fn value(number: f32) rdna2.Operand {
            return .{ .kind = .literal_constant, .value = @bitCast(number) };
        }
    }.value;
    const sample_pc = binding.instruction_pc orelse 0x44;

    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(allocator);
    try program.instructions.appendSlice(allocator, &.{
        // The traced Unity UI shader uses PARAM1.xy as UV and PARAM0 as its
        // per-vertex colour. Keep the output uncompressed so this probe ends
        // before the guest's alpha quantization and packed MRT export.
        .{ .pc = 0, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(0), .src0 = uint(0), .src1 = uint(1), .src2 = uint(0), .src_count = 3 },
        .{ .pc = 4, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(1), .src0 = uint(1), .src1 = uint(1), .src2 = uint(1), .src_count = 3 },
        .{
            .pc = sample_pc,
            .family = .mimg,
            .opcode_id = 0x20,
            .opcode = .image_sample,
            .dst = vgpr(2),
            .src0 = vgpr(0),
            .src1 = sgpr(binding.resource_sgpr),
            .src2 = sgpr(binding.sampler_sgpr),
            .src_count = 3,
            .data_mask = 0xf,
            .image_dimension = .dim_2d,
            .image_address_components = 2,
        },
        .{ .pc = sample_pc + 8, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(6), .src0 = uint(0), .src1 = uint(0), .src2 = uint(0), .src_count = 3 },
        .{ .pc = sample_pc + 12, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(7), .src0 = uint(1), .src1 = uint(0), .src2 = uint(1), .src_count = 3 },
        .{ .pc = sample_pc + 16, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(8), .src0 = uint(2), .src1 = uint(0), .src2 = uint(2), .src_count = 3 },
        .{ .pc = sample_pc + 20, .family = .vintrp, .opcode = .v_interp_mov_f32, .dst = vgpr(9), .src0 = uint(3), .src1 = uint(0), .src2 = uint(3), .src_count = 3 },
        .{ .pc = sample_pc + 24, .opcode = .v_mul_f32, .dst = vgpr(2), .src0 = vgpr(2), .src1 = vgpr(6), .src_count = 2 },
        .{ .pc = sample_pc + 28, .opcode = .v_mul_f32, .dst = vgpr(3), .src0 = vgpr(3), .src1 = vgpr(7), .src_count = 2 },
        .{ .pc = sample_pc + 32, .opcode = .v_mul_f32, .dst = vgpr(4), .src0 = vgpr(4), .src1 = vgpr(8), .src_count = 2 },
        .{ .pc = sample_pc + 36, .opcode = .v_mul_f32, .dst = vgpr(5), .src0 = vgpr(5), .src1 = vgpr(9), .src_count = 2 },
        .{ .pc = sample_pc + 40, .family = .exp, .opcode = .exp, .export_target = 0, .export_enable = 0xf, .export_done = true, .src0 = vgpr(2), .src1 = vgpr(3), .src2 = vgpr(4), .src3 = float(1.0), .src_count = 4 },
        .{ .pc = sample_pc + 48, .family = .sopp, .opcode = .s_endpgm },
    });
    const sampled = [_]rdna2.spirv.SampledImageBinding{binding};
    return rdna2.translateSpirv(allocator, &program, .{
        .stage = .fragment,
        .fragment_extent = fragment_extent,
        .sampled_images = &sampled,
        .parameter_mask = 3,
        .infer_fragment_parameter_mask = false,
    });
}

fn buildFullscreenProbeVertexSpirv(allocator: std.mem.Allocator, flip_v: bool) !rdna2.spirv.Module {
    const vgpr = struct {
        fn at(reg: u32) rdna2.Operand {
            return .{ .kind = .vgpr, .reg = reg };
        }
    }.at;
    const uint = struct {
        fn value(bits: u32) rdna2.Operand {
            return .{ .kind = .integer_inline_constant, .value = bits, .signed_val = @intCast(bits) };
        }
    }.value;
    const float = struct {
        fn value(number: f32) rdna2.Operand {
            return .{ .kind = .literal_constant, .value = @bitCast(number) };
        }
    }.value;

    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(allocator);
    try program.instructions.appendSlice(allocator, &.{
        // Match SharpEmu's fixed fullscreen vertex mapping, with PARAM0.y
        // inverted for the negative-height Vulkan viewport used by guest
        // render targets. Position keeps the original 0..2 triangle mapping.
        // x=(VertexIndex<<1)&2, y=VertexIndex&2. Position is x/y*2-1,
        // while PARAM0 carries the unscaled 0..2 fullscreen UV triangle.
        .{ .pc = 0, .opcode = .v_lshlrev_b32, .dst = vgpr(1), .src0 = uint(1), .src1 = vgpr(0), .src_count = 2 },
        .{ .pc = 4, .opcode = .v_and_b32, .dst = vgpr(1), .src0 = vgpr(1), .src1 = uint(2), .src_count = 2 },
        .{ .pc = 8, .opcode = .v_and_b32, .dst = vgpr(2), .src0 = vgpr(0), .src1 = uint(2), .src_count = 2 },
        .{ .pc = 12, .opcode = .v_cvt_f32_u32, .dst = vgpr(3), .src0 = vgpr(1), .src_count = 1 },
        .{ .pc = 16, .opcode = .v_cvt_f32_u32, .dst = vgpr(4), .src0 = vgpr(2), .src_count = 1 },
        .{ .pc = 20, .opcode = .v_mul_f32, .dst = vgpr(1), .src0 = vgpr(3), .src1 = float(2.0), .src_count = 2 },
        .{ .pc = 24, .opcode = .v_mul_f32, .dst = vgpr(2), .src0 = vgpr(4), .src1 = float(2.0), .src_count = 2 },
        .{ .pc = 28, .opcode = .v_sub_f32, .dst = vgpr(1), .src0 = vgpr(1), .src1 = float(1.0), .src_count = 2 },
        .{ .pc = 32, .opcode = .v_sub_f32, .dst = vgpr(2), .src0 = vgpr(2), .src1 = float(1.0), .src_count = 2 },
        .{ .pc = 36, .opcode = .v_mov_b32, .dst = vgpr(5), .src0 = float(0.0), .src_count = 1 },
        .{ .pc = 40, .opcode = .v_mov_b32, .dst = vgpr(6), .src0 = float(1.0), .src_count = 1 },
        .{ .pc = 44, .opcode = .v_sub_f32, .dst = vgpr(7), .src0 = float(1.0), .src1 = vgpr(4), .src_count = 2 },
        .{ .pc = 48, .family = .exp, .opcode = .exp, .export_target = 0x0c, .export_enable = 0xf, .src0 = vgpr(1), .src1 = vgpr(2), .src2 = vgpr(5), .src3 = vgpr(6), .src_count = 4 },
        .{ .pc = 56, .family = .exp, .opcode = .exp, .export_target = 0x20, .export_enable = 0xf, .export_done = true, .src0 = vgpr(3), .src1 = if (flip_v) vgpr(7) else vgpr(4), .src2 = vgpr(5), .src3 = vgpr(6), .src_count = 4 },
        .{ .pc = 64, .family = .sopp, .opcode = .s_endpgm },
    });
    return rdna2.translateSpirv(allocator, &program, .{
        .stage = .vertex,
        .vertex_index_vgpr = 0,
    });
}

// Diagnostic vertex shader: three positions selected from VertexIndex and
// written to BuiltIn Position without vertex-buffer dependencies.
const graphics_probe_vertex_spirv = [_]u32{
    0x0723_0203, 0x0001_0500, 0x0050_4300, 28,          0,
    0x0002_0011, 1,           0x0003_000e, 0,           1,
    0x0007_000f, 0,           18,          0x6e69_616d, 0,
    9,           10,          0x0004_0047, 9,           11,
    42,          0x0004_0047, 10,          11,          0,
    0x0002_0013, 1,           0x0003_0021, 2,           1,
    0x0002_0014, 3,           0x0004_0015, 4,           32,
    1,           0x0003_0016, 5,           32,          0x0004_0017,
    6,           5,           4,           0x0004_0020, 7,
    1,           4,           0x0004_0020, 8,           3,
    6,           0x0004_002b, 4,           11,          0,
    0x0004_002b, 4,           12,          1,           0x0004_002b,
    4,           13,          2,           0x0004_002b, 5,
    14,          0xbf4c_cccd, 0x0004_002b, 5,           15,
    0x3f4c_cccd, 0x0004_002b, 5,           16,          0,
    0x0004_002b, 5,           17,          0x3f80_0000, 0x0004_003b,
    7,           9,           1,           0x0004_003b, 8,
    10,          3,           0x0005_0036, 1,           18,
    0,           2,           0x0002_00f8, 19,          0x0004_003d,
    4,           20,          9,           0x0005_00aa, 3,
    21,          20,          11,          0x0005_00aa, 3,
    22,          20,          12,          0x0005_00aa, 3,
    23,          20,          13,          0x0006_00a9, 5,
    24,          22,          15,          16,          0x0006_00a9,
    5,           25,          21,          14,          24,
    0x0006_00a9, 5,           26,          23,          15,
    14,          0x0007_0050, 6,           27,          25,
    26,          16,          17,          0x0003_003e, 10,
    27,          0x0001_00fd, 0x0001_0038,
};

// Diagnostic fragment shader: one opaque orange-red color at location zero.
const graphics_probe_fragment_spirv = [_]u32{
    0x0723_0203, 0x0001_0500, 0x0050_4300, 14,          0,
    0x0002_0011, 1,           0x0003_000e, 0,           1,
    0x0006_000f, 4,           11,          0x6e69_616d, 0,
    6,           0x0003_0010, 11,          7,           0x0004_0047,
    6,           30,          0,           0x0002_0013, 1,
    0x0003_0021, 2,           1,           0x0003_0016, 3,
    32,          0x0004_0017, 4,           3,           4,
    0x0004_0020, 5,           3,           4,           0x0004_002b,
    3,           7,           0x3f80_0000, 0x0004_002b, 3,
    8,           0x3e80_0000, 0x0004_002b, 3,           9,
    0x3dcc_cccd, 0x0004_003b, 5,           6,           3,
    0x0005_0036, 1,           11,          0,           2,
    0x0002_00f8, 12,          0x0007_0050, 4,           13,
    7,           8,           9,           7,           0x0003_003e,
    6,           13,          0x0001_00fd, 0x0001_0038,
};

// SPIR-V 1.0: `void main()` with LocalSize(1, 1, 1). The staging copy is
// deliberately separate so the probe validates both compute-pipeline creation
// and transfer/readback synchronization without depending on descriptor code.
const smoke_compute_spirv = [_]u32{
    0x0723_0203, 0x0001_0000, 0x0000_0000, 0x0000_0005, 0x0000_0000,
    0x0002_0011, 0x0000_0001, 0x0003_000e, 0x0000_0000, 0x0000_0001,
    0x0005_000f, 0x0000_0005, 0x0000_0003, 0x6e69_616d, 0x0000_0000,
    0x0006_0010, 0x0000_0003, 0x0000_0011, 0x0000_0001, 0x0000_0001,
    0x0000_0001, 0x0002_0013, 0x0000_0001, 0x0003_0021, 0x0000_0002,
    0x0000_0001, 0x0005_0036, 0x0000_0001, 0x0000_0003, 0x0000_0000,
    0x0000_0002, 0x0002_00f8, 0x0000_0004, 0x0001_00fd, 0x0001_0038,
};

test "compute local size defaults to one and preserves the programmed count" {
    var state = gpu.State{};
    try std.testing.expectEqual(@as(u32, 1), computeLocalSize(&state, 0x207));
    try state.writeRegister(.shader, 0x207, 0);
    try state.writeRegister(.shader, 0x208, 32);
    try std.testing.expectEqual(@as(u32, 1), computeLocalSize(&state, 0x207));
    try std.testing.expectEqual(@as(u32, 32), computeLocalSize(&state, 0x208));
}

test "thread-dimension dispatches convert to Vulkan workgroup counts" {
    try std.testing.expectEqual(
        [3]u32{ 32_640, 1, 1 },
        dispatchGroupCounts(.{ 2_088_960, 1, 1 }, .{ 64, 1, 1 }, 0x61),
    );
    try std.testing.expectEqual(
        [3]u32{ 2, 3, 4 },
        dispatchGroupCounts(.{ 65, 5, 4 }, .{ 64, 2, 1 }, dispatch_initiator_use_thread_dimensions),
    );
    try std.testing.expectEqual(
        [3]u32{ 0, 1, 1 },
        dispatchGroupCounts(.{ 0, 1, 1 }, .{ 64, 1, 1 }, dispatch_initiator_use_thread_dimensions),
    );
}

test "group-dimension dispatches are preserved" {
    try std.testing.expectEqual(
        [3]u32{ 7, 5, 3 },
        dispatchGroupCounts(.{ 7, 5, 3 }, .{ 64, 2, 1 }, 0x41),
    );
}

test "Vulkan version packing matches the registry layout" {
    const version = vk.makeApiVersion(0, 1, 4, 321);
    try std.testing.expectEqual(@as(u32, 1), vk.apiMajor(version));
    try std.testing.expectEqual(@as(u32, 4), vk.apiMinor(version));
    try std.testing.expectEqual(@as(u32, 321), vk.apiPatch(version));
}

test "graphics probe is opt-in and carries standalone shader modules" {
    try std.testing.expect(!(Options{}).enable_graphics_probe);
    try std.testing.expectEqual(@as(u32, 0x0723_0203), graphics_probe_vertex_spirv[0]);
    try std.testing.expectEqual(@as(u32, 0x0723_0203), graphics_probe_fragment_spirv[0]);
    try std.testing.expect(graphics_probe_vertex_spirv.len > 32);
    try std.testing.expect(graphics_probe_fragment_spirv.len > 24);
    try std.testing.expectEqual(@as(usize, 64 * 64 * 4), graphics_probe_bytes);
}

test "display buffers become bounded 32-bit color targets" {
    const tiled = displayColorTarget(.{
        .address = 0x1234_0000,
        .width = 3840,
        .height = 2160,
        .pitch_in_pixels = 3840,
        .tiling_mode = 0,
    }).?;
    try std.testing.expectEqual(@as(u64, 0x1234_0000), tiled.address);
    try std.testing.expectEqual(@as(u8, 10), tiled.format);
    try std.testing.expectEqual(gpu.resources.TileMode.render_target, tiled.tile_mode);
    try std.testing.expectEqual(@as(u8, 0xf), tiled.write_mask);
    const layout = try gpu.SurfaceLayout.fromColorTarget(tiled);
    try std.testing.expectEqual(@as(u8, 4), layout.block.bytes_per_element);
    try std.testing.expectEqual(@as(u32, 3840), layout.row_pitch_elements);

    const linear = displayColorTarget(.{
        .address = 0x5678_0000,
        .width = 1280,
        .height = 720,
        .pitch_in_pixels = 0,
        .tiling_mode = 1,
    }).?;
    try std.testing.expectEqual(gpu.resources.TileMode.linear, linear.tile_mode);
    try std.testing.expectEqual(@as(u32, 1280), linear.pitch);

    try std.testing.expect(displayColorTarget(.{
        .address = 0x1000,
        .width = 1920,
        .height = 1080,
        .pitch_in_pixels = 1280,
    }) == null);
}

test "identity fragment scale only fills registers the evaluator left unknown" {
    const one_bits: u32 = @bitCast(@as(f32, 1.0));
    var registers: [8]gpu.ShaderSpirvScalarRegister = undefined;
    // A sprite batcher fills a solid rectangle with scale 0 and a colour bias;
    // that zero is a resolved constant and must survive untouched.
    registers[0] = .{ .register = 16, .value = 0 };
    registers[1] = .{ .register = 17, .value = 0 };
    registers[2] = .{ .register = 19, .value = 0 };

    const count = ensureIdentityFragmentScale(&registers, 3);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u32, 0), registers[0].value);
    try std.testing.expectEqual(@as(u32, 0), registers[1].value);
    try std.testing.expectEqual(@as(u32, 0), registers[2].value);
    // s18 was absent, so it is the only one that gets the identity default.
    try std.testing.expectEqual(@as(u32, 18), registers[3].register);
    try std.testing.expectEqual(one_bits, registers[3].value);
}

test "a uniform dcc key resolves to the colour the hardware would return" {
    var descriptor = std.mem.zeroes(gpu.resources.ColorTarget);
    descriptor.format = 10;
    descriptor.number_type = 0;
    descriptor.component_swap = 0;
    descriptor.clear_words = .{ 0x8040_2010, 0 };

    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, dccClearTexel(0x00, descriptor).?);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, dccClearTexel(0x40, descriptor).?);
    try std.testing.expectEqual([4]u8{ 0x10, 0x20, 0x40, 0x80 }, dccClearTexel(0x20, descriptor).?);
    // Uncompressed: the surface itself is the only honest source.
    try std.testing.expect(dccClearTexel(0xff, descriptor) == null);
    // An encoding the clear-word unpack does not model keeps the raw path.
    descriptor.format = 11;
    try std.testing.expect(dccClearTexel(0x20, descriptor) == null);
}

test "RGBA16F color targets and DCC clears preserve native half-float texels" {
    var descriptor = std.mem.zeroes(gpu.resources.ColorTarget);
    descriptor.format = 12;
    descriptor.number_type = 7;
    descriptor.component_swap = 0;
    descriptor.clear_words = .{ 0x3800_3400, 0x3c00_3a00 };

    const format = colorTargetFormat(descriptor).?;
    try std.testing.expectEqual(vk.format_r16g16b16a16_sfloat, format.vulkan);
    try std.testing.expectEqual(@as(u8, 8), format.bytes_per_texel);

    const fixed = colorDccClearTexel(0x40, descriptor).?;
    try std.testing.expectEqual(@as(u8, 8), fixed.length);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c },
        fixed.bytes[0..fixed.length],
    );

    const registers = colorDccClearTexel(0x20, descriptor).?;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x34, 0x00, 0x38, 0x00, 0x3a, 0x00, 0x3c },
        registers.bytes[0..registers.length],
    );
    try std.testing.expect(colorDccClearTexel(0xff, descriptor) == null);
}

test "MSAA color targets retain their allocation while using one host sample" {
    var descriptor = std.mem.zeroes(gpu.resources.ColorTarget);
    descriptor.address = 0x1234_0000;
    descriptor.width = 1920;
    descriptor.height = 1080;
    descriptor.format = 10;
    descriptor.tile_mode = .render_target;
    descriptor.samples_log2 = 2;
    descriptor.fragments_log2 = 1;
    descriptor.fmask_compression = true;
    descriptor.fmask_address = 0x5678_0000;

    const host = hostColorTargetDescriptor(descriptor);
    try std.testing.expectEqual(descriptor.address, host.address);
    try std.testing.expectEqual(descriptor.width, host.width);
    try std.testing.expectEqual(descriptor.height, host.height);
    try std.testing.expectEqual(@as(u8, 0), host.samples_log2);
    try std.testing.expectEqual(@as(u8, 0), host.fragments_log2);
    try std.testing.expect(!host.fmask_compression);
    try std.testing.expectEqual(@as(u64, 0), host.fmask_address);
}

test "CMASK clear and expanded nibbles materialize only the selected 8x8 blocks" {
    const layout = try gpu.CmaskLayout.init(16, 8, 1, 0, 16);
    var metadata = [_]u8{0xff} ** gpu.CmaskLayout.block_bytes;
    try layout.setValue(&metadata, 0, 0, 0, 0);
    const stats = classifyCmaskBlocks(layout, &metadata).?;
    try std.testing.expectEqual(@as(u32, 1), stats.clear_blocks);
    try std.testing.expectEqual(@as(u32, 1), stats.expanded_blocks);

    var frame = [_]u8{0xaa} ** (16 * 8 * 4);
    const clear = [4]u8{ 0x10, 0x20, 0x40, 0x80 };
    applyCmaskClearBlocks(layout, &metadata, &frame, clear);
    try std.testing.expectEqualSlices(u8, &clear, frame[0..4]);
    try std.testing.expectEqualSlices(u8, &clear, frame[(7 * 16 + 7) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xaa} ** 4, frame[8 * 4 ..][0..4]);

    try layout.setValue(&metadata, 8, 0, 0, 5);
    try std.testing.expect(classifyCmaskBlocks(layout, &metadata) == null);
}

test "HTILE fast-clear words materialize exact depth and stencil blocks" {
    var target = std.mem.zeroes(gpu.resources.DepthTarget);
    target.read_address = 0x1000_0000;
    target.write_address = target.read_address;
    target.htile_address = 0x2000_0000;
    target.width = 16;
    target.height = 8;
    target.format = 3;
    target.tile_mode = .depth;
    target.stencil_tile_mode = .depth;
    target.samples_log2 = 2;
    target.htile_enabled = true;
    target.htile_pipe_aligned = true;
    target.tile_stencil_disabled = true;

    const htile = try gpu.HtileLayout.fromDepthTarget(target);
    const metadata = try std.testing.allocator.alloc(u8, @intCast(htile.required_bytes));
    defer std.testing.allocator.free(metadata);
    var word_offset: usize = 0;
    while (word_offset < metadata.len) : (word_offset += 4) {
        std.mem.writeInt(u32, metadata[word_offset..][0..4], gpu.HtileLayout.expanded_depth, .little);
    }
    try htile.setWord(metadata, 0, 0, 0, 0x0000_0000);
    try htile.setWord(metadata, 8, 0, 0, 0xffff_fff0);
    const stats = classifyHtileBlocks(htile, metadata, true).?;
    try std.testing.expectEqual(@as(u32, 1), stats.clear_zero_blocks);
    try std.testing.expectEqual(@as(u32, 1), stats.clear_one_blocks);
    try std.testing.expectEqual(@as(u32, 0), stats.base_blocks);

    const depth_texture = try gpu.TextureLayout.fromDepthTarget(target);
    const depth = try depth_texture.base();
    const depth_allocation = try std.testing.allocator.alloc(u8, @intCast(depth_texture.required_source_bytes));
    defer std.testing.allocator.free(depth_allocation);
    @memset(depth_allocation, 0xaa);
    try applyHtileDepthFastClears(htile, metadata, target, depth, depth_allocation);
    for (0..depth.samples()) |sample| {
        const zero_offset: usize = @intCast(try depth.sourceByteOffset(7, 7, 0, @intCast(sample)));
        const one_offset: usize = @intCast(try depth.sourceByteOffset(8, 0, 0, @intCast(sample)));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, depth_allocation[zero_offset..][0..4], .little));
        try std.testing.expectEqual(
            @as(u32, @bitCast(@as(f32, 1.0))),
            std.mem.readInt(u32, depth_allocation[one_offset..][0..4], .little),
        );
    }

    target.tile_stencil_disabled = false;
    target.stencil_format = 1;
    try htile.setWord(metadata, 0, 0, 0, 0x0000_00f0);
    try htile.setWord(metadata, 8, 0, 0, 0xfffc_00f0);
    const stencil_texture = try gpu.TextureLayout.fromStencilTarget(target);
    const stencil = try stencil_texture.base();
    const stencil_allocation = try std.testing.allocator.alloc(u8, @intCast(stencil_texture.required_source_bytes));
    defer std.testing.allocator.free(stencil_allocation);
    @memset(stencil_allocation, 0xaa);
    try applyHtileStencilFastClears(htile, metadata, target, stencil, stencil_allocation);
    for (0..stencil.samples()) |sample| {
        const stencil_zero: usize = @intCast(try stencil.sourceByteOffset(7, 7, 0, @intCast(sample)));
        const stencil_one: usize = @intCast(try stencil.sourceByteOffset(8, 0, 0, @intCast(sample)));
        try std.testing.expectEqual(@as(u8, 0), stencil_allocation[stencil_zero]);
        try std.testing.expectEqual(@as(u8, 0), stencil_allocation[stencil_one]);
    }
}

test "CMASK write overlap checks use checked half-open guest ranges" {
    try std.testing.expect(byteRangesOverlap(0x1000, 4, 0x1003, 8));
    try std.testing.expect(!byteRangesOverlap(0x1000, 4, 0x1004, 8));
    try std.testing.expect(!byteRangesOverlap(0x1000, 0, 0x1000, 8));
    try std.testing.expect(byteRangesOverlap(std.math.maxInt(u64) - 1, 8, std.math.maxInt(u64), 1));
}

test "dual image clear matcher requires the complete bounded kernel" {
    const register = struct {
        fn make(kind: gpu.ShaderOperandKind, index: u32) gpu.ShaderOperand {
            return .{ .kind = kind, .reg = index };
        }
    }.make;
    const integer = struct {
        fn make(value: u32) gpu.ShaderOperand {
            return .{ .kind = .integer_inline_constant, .value = value };
        }
    }.make;
    var instructions = [_]gpu.ShaderInstruction{.{}} ** 18;
    const opcodes = [_]gpu.ShaderOpcode{
        .s_inst_prefetch,
        .v_lshl_add_u32,
        .s_buffer_load_dwordx4,
        .v_lshl_add_u32,
        .s_waitcnt,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .v_mov_b32,
        .s_load_dwordx8,
        .image_store,
        .s_waitcnt,
        .image_store,
        .s_endpgm,
    };
    for (&instructions, opcodes) |*instruction, opcode| instruction.opcode = opcode;
    instructions[1].dst = register(.vgpr, 8);
    instructions[1].src0 = register(.sgpr, 14);
    instructions[1].src1 = integer(2);
    instructions[1].src2 = register(.vgpr, 0);
    instructions[2].dst = register(.sgpr, 16);
    instructions[2].src0 = register(.sgpr, 8);
    instructions[2].memory_offset = 384;
    instructions[3].dst = register(.vgpr, 9);
    instructions[3].src0 = register(.sgpr, 15);
    instructions[3].src1 = integer(2);
    instructions[3].src2 = register(.vgpr, 1);
    for (5..8) |index| {
        instructions[index].dst = register(.vgpr, @intCast(index - 5));
        instructions[index].src0 = register(.sgpr, @intCast(16 + index - 5));
    }
    instructions[8].dst = register(.vgpr, 3);
    instructions[8].src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, -1.0)) };
    for (9..12) |index| {
        instructions[index].dst = register(.vgpr, @intCast(index - 9 + 4));
        instructions[index].src0 = integer(0);
    }
    instructions[12].dst = register(.vgpr, 7);
    instructions[12].src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, -1.0)) };
    instructions[13].dst = register(.sgpr, 24);
    instructions[13].src0 = register(.sgpr, 12);
    instructions[14].dst = register(.vgpr, 0);
    instructions[14].src0 = register(.vgpr, 8);
    instructions[14].src1 = register(.sgpr, 0);
    instructions[14].data_mask = 0xf;
    instructions[16].dst = register(.vgpr, 4);
    instructions[16].src0 = register(.vgpr, 8);
    instructions[16].src1 = register(.sgpr, 24);
    instructions[16].data_mask = 0xf;

    try std.testing.expect(matchesDualImageClear(&instructions));
    instructions[16].data_mask = 0x7;
    try std.testing.expect(!matchesDualImageClear(&instructions));
}

test "sampled image views honor sRGB and destination selectors" {
    try std.testing.expectEqual(vk.format_r8_unorm, sampledImageFormat(1, false).?);
    try std.testing.expectEqual(vk.format_r8g8_unorm, sampledImageFormat(14, false).?);
    try std.testing.expectEqual(vk.format_b10g11r11_ufloat_pack32, sampledImageFormat(36, false).?);
    try std.testing.expectEqual(vk.format_b10g11r11_ufloat_pack32, sampledImageFormat(36, true).?);
    try std.testing.expectEqual(vk.format_a2b10g10r10_unorm_pack32, sampledImageFormat(50, false).?);
    try std.testing.expectEqual(vk.format_a2b10g10r10_unorm_pack32, sampledImageFormat(50, true).?);
    try std.testing.expectEqual(@as(u8, 4), storageImageBytesPerTexel(50));
    try std.testing.expectEqual(vk.format_r8g8b8a8_unorm, sampledImageFormat(56, false).?);
    try std.testing.expectEqual(vk.format_r8g8b8a8_srgb, sampledImageFormat(56, true).?);
    try std.testing.expectEqual(vk.format_r16g16b16a16_sfloat, sampledImageFormat(71, false).?);
    try std.testing.expectEqual(vk.format_r16g16b16a16_sfloat, sampledImageFormat(71, true).?);
    try std.testing.expectEqual(vk.format_r8g8b8a8_srgb, sampledImageFormat(130, false).?);
    try std.testing.expectEqual(vk.format_bc3_unorm_block, sampledImageFormat(173, false).?);
    try std.testing.expectEqual(vk.format_bc3_srgb_block, sampledImageFormat(173, true).?);
    try std.testing.expectEqual(vk.format_bc3_srgb_block, sampledImageFormat(174, false).?);
    try std.testing.expectEqual(vk.format_bc7_unorm_block, sampledImageFormat(181, false).?);
    try std.testing.expectEqual(vk.format_bc7_srgb_block, sampledImageFormat(181, true).?);
    try std.testing.expectEqual(vk.format_bc7_srgb_block, sampledImageFormat(182, false).?);
    try std.testing.expectEqual(@as(u8, 4), storageImageBytesPerTexel(130));
    try std.testing.expectEqual(@as(u8, 8), storageImageBytesPerTexel(169));
    try std.testing.expectEqual(@as(u8, 16), storageImageBytesPerTexel(174));
    try std.testing.expectEqual(@as(u8, 16), storageImageBytesPerTexel(182));
    try std.testing.expectEqual(@as(u32, 0), vulkanMinMagFilter(0));
    try std.testing.expectEqual(@as(u32, 1), vulkanMinMagFilter(1));
    try std.testing.expectEqual(@as(u32, 0), vulkanMinMagFilter(2));
    try std.testing.expectEqual(@as(u32, 1), vulkanMinMagFilter(3));
    try std.testing.expect(sampledImageFormat(0, false) == null);

    const identity = try sampledImageComponents(.{ 4, 5, 6, 7 });
    try std.testing.expectEqual(vk.component_swizzle_r, identity.r);
    try std.testing.expectEqual(vk.component_swizzle_g, identity.g);
    try std.testing.expectEqual(vk.component_swizzle_b, identity.b);
    try std.testing.expectEqual(vk.component_swizzle_a, identity.a);

    const blue_one_red_zero = try sampledImageComponents(.{ 6, 1, 4, 0 });
    try std.testing.expectEqual(vk.component_swizzle_b, blue_one_red_zero.r);
    try std.testing.expectEqual(vk.component_swizzle_one, blue_one_red_zero.g);
    try std.testing.expectEqual(vk.component_swizzle_r, blue_one_red_zero.b);
    try std.testing.expectEqual(vk.component_swizzle_zero, blue_one_red_zero.a);
    try std.testing.expectError(Error.UnsupportedSampledImage, sampledImageComponents(.{ 2, 5, 6, 7 }));
}

test "unnormalized guest samplers satisfy Vulkan restrictions" {
    const descriptor = try gpu.resources.decodeSamplerDescriptor(&.{
        1 << 15,
        0x00ff_f123,
        0x0540_0100,
        0,
    });
    const info = try guestSamplerCreateInfo(descriptor);

    try std.testing.expectEqual(@as(vk.Bool32, 1), info.unnormalized_coordinates);
    try std.testing.expectEqual(info.magnification_filter, info.minification_filter);
    try std.testing.expectEqual(@as(u32, 0), info.mipmap_mode);
    try std.testing.expectEqual(@as(u32, 2), info.address_mode_u);
    try std.testing.expectEqual(@as(u32, 2), info.address_mode_v);
    try std.testing.expectEqual(@as(u32, 2), info.address_mode_w);
    try std.testing.expectEqual(@as(f32, 0), info.mip_lod_bias);
    try std.testing.expectEqual(@as(f32, 0), info.minimum_lod);
    try std.testing.expectEqual(@as(f32, 0), info.maximum_lod);
}

test "graphics SRT slots allow multiple images to share one sampler" {
    const mappings = [_]gpu.ShaderSpirvSampledImageBinding{
        .{ .resource_sgpr = 8, .sampler_sgpr = 32, .descriptor_index = 0 },
        .{ .resource_sgpr = 16, .sampler_sgpr = 32, .descriptor_index = 1 },
    };
    try std.testing.expectEqual(@as(usize, 0), graphicsSrtImageSlot(mappings[0..0], 8));
    try std.testing.expectEqual(@as(usize, 1), graphicsSrtImageSlot(mappings[0..1], 16));
    try std.testing.expectEqual(@as(usize, 0), graphicsSrtSamplerSlot(mappings[0..1], 32));
    try std.testing.expectEqual(@as(usize, 0), graphicsSrtSamplerSlot(&mappings, 32));
    try std.testing.expectEqual(@as(usize, 1), graphicsSrtSamplerSlot(&mappings, 40));
}

test "vertex attributes keep distinct PC-qualified storage mappings" {
    try std.testing.expect(canReuseStorageMapping(false, 3, 3));
    try std.testing.expect(!canReuseStorageMapping(false, 3, 4));
    try std.testing.expect(!canReuseStorageMapping(false, null, 3));
    try std.testing.expect(!canReuseStorageMapping(true, 3, 3));
}

test "compute resources retain temporal scalar load specializations" {
    const resources = ComputeResources{};
    try std.testing.expectEqual(
        @as(usize, gpu.scalar_provenance.maximum_scalar_specializations),
        resources.scalar_registers.len,
    );
    try std.testing.expect(resources.scalar_registers.len > gpu.scalar_provenance.maximum_scalar_registers);
}

test "progress dumps select bounded presentation checkpoints" {
    try std.testing.expect(shouldDumpProgressFrame(8));
    try std.testing.expect(shouldDumpProgressFrame(64));
    try std.testing.expect(shouldDumpProgressFrame(128));
    try std.testing.expect(!shouldDumpProgressFrame(7));
    try std.testing.expect(!shouldDumpProgressFrame(129));
}

test "RGBA occupancy preserves black alpha and destination alpha is explicit" {
    var pixels = [_]u8{
        0, 0, 0, 0,
        0, 0, 0, 17,
        5, 0, 0, 31,
    };
    try std.testing.expectEqual(@as(u32, 2), countNonzeroRgba(&pixels));
    forceDestinationAlphaOne(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, &.{ pixels[3], pixels[7], pixels[11] });
}

test "typed image clear texels use the descriptor number format" {
    const rgba = [4]u8{ 4, 5, 6, 7 };
    const unorm = packImageStoreTexel(56, .{
        @bitCast(@as(f32, 0.0)),
        @bitCast(@as(f32, 0.5)),
        @bitCast(@as(f32, 1.0)),
        @bitCast(@as(f32, 2.0)),
    }, 0xf, rgba).?;
    try std.testing.expectEqual(@as(u8, 4), unorm.length);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255, 255 }, unorm.bytes[0..unorm.length]);

    const rgba_uint = packImageStoreTexel(60, .{ 0, 1, 255, 300 }, 0xf, rgba).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 255, 255 }, rgba_uint.bytes[0..rgba_uint.length]);
    const bgra = packImageStoreTexel(60, .{ 0, 1, 255, 300 }, 0xf, .{ 6, 5, 4, 7 }).?;
    try std.testing.expectEqualSlices(u8, &.{ 255, 1, 0, 255 }, bgra.bytes[0..bgra.length]);
    const missing_green = packImageStoreTexel(60, .{ 0, 1, 255, 300 }, 0xf, .{ 4, 4, 6, 7 }).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, missing_green.bytes[0..missing_green.length]);

    const r_uint = packImageStoreTexel(5, .{ 300, 0, 0, 0 }, 0x1, rgba).?;
    try std.testing.expectEqual(@as(u8, 1), r_uint.length);
    try std.testing.expectEqual(@as(u8, 255), r_uint.bytes[0]);

    const r16_uint = packImageStoreTexel(11, .{ 0x1234, 0, 0, 0 }, 0xf, rgba).?;
    try std.testing.expectEqual(@as(u8, 2), r16_uint.length);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, r16_uint.bytes[0..2], .little));

    const r32_uint = packImageStoreTexel(20, .{ 0x1234_5678, 0, 0, 0 }, 0xf, rgba).?;
    try std.testing.expectEqual(@as(u8, 4), r32_uint.length);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, r32_uint.bytes[0..4], .little));

    const rgba16_float = packImageStoreTexel(71, .{
        @bitCast(@as(f32, 0.0)),
        @bitCast(@as(f32, 0.5)),
        @bitCast(@as(f32, 1.0)),
        @bitCast(@as(f32, -2.0)),
    }, 0xf, rgba).?;
    try std.testing.expectEqual(@as(u8, 8), rgba16_float.length);
    try std.testing.expectEqual(@as(u16, @bitCast(@as(f16, 0.5))), std.mem.readInt(u16, rgba16_float.bytes[2..4], .little));
    try std.testing.expectEqual(@as(u16, @bitCast(@as(f16, -2.0))), std.mem.readInt(u16, rgba16_float.bytes[6..8], .little));

    const rgba32_float = packImageStoreTexel(77, .{
        @bitCast(@as(f32, 0.0)),
        @bitCast(@as(f32, 0.5)),
        @bitCast(@as(f32, 1.0)),
        @bitCast(@as(f32, -2.0)),
    }, 0xf, rgba).?;
    try std.testing.expectEqual(@as(u8, 16), rgba32_float.length);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.5))), std.mem.readInt(u32, rgba32_float.bytes[4..8], .little));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, -2.0))), std.mem.readInt(u32, rgba32_float.bytes[12..16], .little));

    try std.testing.expect(packImageStoreTexel(56, .{ 0, 0, 0, 0 }, 0x1, rgba) == null);
    try std.testing.expect(packImageStoreTexel(61, .{ 0, 0, 0, 0 }, 0xf, rgba) == null);
}

test "whole image clear plans are bounded and reject partial dispatches" {
    var image = gpu.ImageDescriptor{
        .address = 0x2000_0000,
        .width = 64,
        .height = 64,
        .depth_or_layers = 1,
        .pitch = 64,
        .unified_format = 77,
        .tile_mode = .linear,
        .image_type = .color_2d,
        .dst_select = .{ 4, 5, 6, 7 },
        .base_level = 0,
        .last_level = 0,
        .base_array = 0,
        .array_pitch = 0,
        .max_mip = 0,
        .min_lod = 0,
        .min_lod_warning = 0,
        .bc_swizzle = 0,
        .metadata_address = 0x3000_0000,
        .dcc_enabled = false,
        .cmask_fast_clear = false,
        .fmask_compression = false,
        .cmask_address = 0,
        .fmask_address = 0,
        .dcc_address = 0,
        .descriptor_flags = 0,
        .extended = true,
    };
    const clear = planWholeImageClear(
        image,
        .{ 0, @bitCast(@as(f32, 0.5)), @bitCast(@as(f32, 1.0)), @bitCast(@as(f32, -1.0)) },
        0xf,
        64,
        64,
    ).?;
    try std.testing.expectEqual(@as(u8, 16), clear.texel.length);
    try std.testing.expect(clear.allocation_bytes <= 256 * 1024 * 1024);
    try std.testing.expect(planWholeImageClear(image, .{ 0, 0, 0, 0 }, 0xf, 63, 64) == null);
    image.dcc_enabled = true;
    try std.testing.expect(planWholeImageClear(image, .{ 0, 0, 0, 0 }, 0xf, 64, 64) == null);
}

test "volume upload source index uses x y and z record strides" {
    try std.testing.expectEqual(@as(u64, 3 * 4 + 2 * 64 + 5 * 1024), try volumeSourceIndex(.{ 64, 4, 1024 }, 3, 2, 5));
    try std.testing.expectEqual(@as(u64, 15 + 15 * 16 + 15 * 256), try volumeSourceIndex(.{ 16, 1, 256 }, 15, 15, 15));
}

test "presentation scaling letterboxes RGBA and converts BGRA" {
    const pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const frame = PresentedFrame{
        .pixels = &pixels,
        .width = 2,
        .height = 2,
        .row_pitch_bytes = 8,
        .guest_address = 0x1000,
        .flip = .{
            .video_out_handle = 1,
            .display_buffer_index = 0,
            .mode = 1,
            .argument = 7,
        },
    };
    var rgba: [4 * 4 * 4]u8 = undefined;
    scalePresentedFrame(&rgba, 4, 4, vk.format_r8g8b8a8_unorm, frame);
    try std.testing.expectEqualSlices(u8, pixels[0..4], rgba[0..4]);
    try std.testing.expectEqualSlices(u8, pixels[12..16], rgba[60..64]);

    var bgra: [2 * 4 * 4]u8 = undefined;
    scalePresentedFrame(&bgra, 2, 4, vk.format_b8g8r8a8_unorm, frame);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, bgra[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, bgra[8..12]);
}

test "frame rate counter emits a one-second rolling rate" {
    var counter = FrameRateCounter{};
    try std.testing.expect(counter.note(1) == null);
    for (1..61) |frame| {
        const now = 1 + @as(u64, frame) * std.time.ns_per_s / 60;
        if (frame < 60) {
            try std.testing.expect(counter.note(now) == null);
        } else {
            try std.testing.expectEqual(@as(u32, 600), counter.note(now).?);
        }
    }
    try std.testing.expect(counter.note(1 + std.time.ns_per_s / 60) == null);
}

test "NGG auto rectangle uses a triangle strip topology" {
    try std.testing.expectEqual(
        vk.primitive_topology_triangle_strip,
        guestPrimitiveTopology(7, .{ .vertex_count = 4 }),
    );
    try std.testing.expectEqual(
        vk.primitive_topology_triangle_list,
        guestPrimitiveTopology(7, .{ .index_count = 6 }),
    );
    try std.testing.expectEqual(
        vk.primitive_topology_triangle_list,
        guestPrimitiveTopology(4, .{ .vertex_count = 3 }),
    );
}

test "depth attachment formats follow the stored precision" {
    var descriptor = std.mem.zeroes(gpu.resources.DepthTarget);
    descriptor.format = 1;
    try std.testing.expectEqual(@as(?u32, vk.format_d16_unorm), depthTargetFormat(descriptor));
    descriptor.format = 3;
    try std.testing.expectEqual(@as(?u32, vk.format_d32_sfloat), depthTargetFormat(descriptor));
    // A precision this path cannot reproduce is refused rather than rounded to
    // a nearby one, which would silently change which fragments survive.
    descriptor.format = 2;
    try std.testing.expectEqual(@as(?u32, null), depthTargetFormat(descriptor));
}

test "guest depth compare selectors map onto the host operations" {
    // Both enumerations run never, less, equal, less-or-equal, greater,
    // not-equal, greater-or-equal, always.
    for (0..8) |function| {
        try std.testing.expectEqual(
            @as(u32, @intCast(function)),
            depthCompareOperation(@intCast(function)),
        );
    }
}

test "a depth attachment is refused when it cannot back a single-sample pass" {
    var descriptor = std.mem.zeroes(gpu.resources.DepthTarget);
    descriptor.format = 3;
    descriptor.width = 1920;
    descriptor.height = 1080;
    descriptor.write_address = 0x2000;

    const plane = Renderer.guestDepthTarget(descriptor) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 0x2000), plane.address);
    try std.testing.expectEqual(vk.format_d32_sfloat, plane.format);

    // Multi-sample depth would have to resolve against a multi-sample colour
    // attachment, which the colour path does not create.
    var multisample = descriptor;
    multisample.samples_log2 = 2;
    try std.testing.expect(Renderer.guestDepthTarget(multisample) == null);

    // Read-only bindings still name the allocation through the read address.
    var read_only = descriptor;
    read_only.write_address = 0;
    read_only.read_address = 0x3000;
    const fallback = Renderer.guestDepthTarget(read_only) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 0x3000), fallback.address);
}

test "depth allocations compare by surface, not by clear value" {
    const base = GuestDepthTarget{
        .address = 0x4000,
        .width = 1280,
        .height = 720,
        .guest_format = 3,
        .format = vk.format_d32_sfloat,
        .tile_mode = .depth,
        .base_array_slice = 0,
        .mip_level = 0,
        .clear_depth = 1.0,
    };
    var recleared = base;
    recleared.clear_depth = 0.0;
    try std.testing.expect(base.sameAllocation(recleared));

    var resized = base;
    resized.height = 1080;
    try std.testing.expect(!base.sameAllocation(resized));
}
