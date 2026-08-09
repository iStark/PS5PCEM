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
const maximum_compute_pipelines = 256;
const maximum_graphics_pipelines = 256;
const maximum_staged_buffer_bytes = 128 * 1024 * 1024;
/// Large compute outputs are overwhelmingly GPU-only working sets. Reading
/// them over PCIe after every dispatch serializes work that remains resident
/// on the console; keep those allocations authoritative until an actual guest
/// or resource read needs their bytes.
const deferred_storage_write_min_bytes = 1024 * 1024;
const maximum_frame_bytes = 128 * 1024 * 1024;
const maximum_completed_frames = 16;
const maximum_render_targets = 16;
const maximum_sampled_images = 32;
/// One DCC key byte covers this many bytes of the compressed colour surface.
const dcc_block_bytes = 256;
/// Bounds the key read for a fast-clear probe; covers surfaces up to 1 GiB.
const maximum_dcc_key_bytes = 4 * 1024 * 1024;
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
    state: GraphicsPipelineState,
    vertex_words: []u32,
    fragment_words: []u32,
    pipeline: vk.Pipeline,
    last_used_sequence: u64,
};

const GraphicsPipelineState = extern struct {
    width: u32,
    height: u32,
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

    fn default(width: u32, height: u32) GraphicsPipelineState {
        return .{
            .width = width,
            .height = height,
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
        };
    }
};

const GuestColorTarget = struct {
    descriptor: gpu.resources.ColorTarget,
    layout: gpu.SurfaceLayout,
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

/// Some final compositors omit CB registers because the following VideoOut
/// flip names the scanout allocation. Keep only the most recent such draw.
const PendingGuestDraw = struct {
    state: gpu.State,
    draw: GuestDraw,
    vertex_stage: gpu.resources.ShaderStage,
};

const ComputeShaderFailure = struct {
    address: u64,
    err: anyerror,
};

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
    readback: OwnedBuffer,
    initialized: bool = false,
    gpu_generation: u64 = 0,
    host_generation: u64 = 0,
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
};

const GraphicsResources = struct {
    images: [maximum_storage_descriptors]PreparedSampledImage = undefined,
    image_count: usize = 0,
    mappings: [maximum_storage_descriptors]gpu.ShaderSpirvSampledImageBinding = undefined,
    mapping_count: usize = 0,

    fn deinit(self: *GraphicsResources, renderer: *Renderer) void {
        _ = renderer;
        self.* = undefined;
    }
};

const PipelineLookup = struct {
    pipeline: vk.Pipeline,
    cache_hit: bool,
};

const ComputeResources = struct {
    mappings: [maximum_storage_descriptors]gpu.ShaderSpirvStorageBufferBinding = undefined,
    mapping_count: usize = 0,
    scalar_registers: [gpu.resources.maximum_user_data_words]gpu.ShaderSpirvScalarRegister = undefined,
    scalar_count: usize = 0,
    addresses: [maximum_storage_descriptors]u64 = @splat(0),
    sizes: [maximum_storage_descriptors]usize = @splat(0),
    occupied: [maximum_storage_descriptors]bool = @splat(false),
    writable: [maximum_storage_descriptors]bool = @splat(false),
    specialized_scalar_prefix_end: u32 = 0,

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
};

const CachedSampledImage = struct {
    guest_address: u64,
    width: u32,
    height: u32,
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
    compute_pipeline_layout: vk.PipelineLayout,
    driver_pipeline_cache: vk.PipelineCache,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    loader_api_version: u32,
    device_info: DeviceInfo,
    validation_enabled: bool,
    graphics_probe_enabled: bool,
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
    latest_render_target_index: ?usize = null,
    render_target_sequence: u64 = 0,
    completed_frames: std.ArrayList(CachedFrame) = .empty,
    latest_frame_index: ?usize = null,
    frame_sequence: u64 = 0,
    presentation_sink: ?PresentationSink = null,
    display_buffer_resolver: ?DisplayBufferResolver = null,
    pending_targetless_draw: ?*PendingGuestDraw = null,
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
    emulated_image_store_dispatches: u64 = 0,
    emulated_volume_copies: u64 = 0,
    reported_dual_image_clear_fallback: bool = false,
    reported_fast_clear_seeds: u32 = 0,
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
    last_shader_failure_address: u64 = 0,
    last_shader_failure_stage: ?gpu.resources.ShaderStage = null,
    last_shader_failure_error: ?anyerror = null,
    last_interface_vertex_address: u64 = 0,
    last_interface_fragment_address: u64 = 0,
    reported_interface_pairs: u8 = 0,
    reported_vertex_storage_bindings: bool = false,
    reported_draw_errors: [16]?anyerror = @splat(null),
    reported_compute_shader_failures: [32]?ComputeShaderFailure = @splat(null),
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
            .stage_flags = vk.shader_stage_fragment_bit,
        };
        const descriptor_bindings = [_]vk.DescriptorSetLayoutBinding{ storage_binding, sampled_image_binding };
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
            .descriptor_count = maximum_storage_descriptors,
        };
        const image_pool_size = vk.DescriptorPoolSize{
            .descriptor_type = vk.descriptor_type_combined_image_sampler,
            .descriptor_count = maximum_storage_descriptors,
        };
        const pool_sizes = [_]vk.DescriptorPoolSize{ pool_size, image_pool_size };
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

        return .{
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
            .window_presentation = window_presentation,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.device_functions.device_wait_idle(self.device);
        if (self.pending_targetless_draw) |pending| self.allocator.destroy(pending);
        for (self.render_targets.items) |target| self.destroyCachedRenderTarget(target);
        self.render_targets.deinit(self.allocator);
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
        for (self.completed_frames.items) |*frame| frame.pixels.deinit(self.allocator);
        self.completed_frames.deinit(self.allocator);
        self.guest_frame_scratch.deinit(self.allocator);
        for (self.guest_buffers.items) |entry| {
            self.destroyBuffer(entry.device_local);
        }
        self.guest_buffers.deinit(self.allocator);
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
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
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
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
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
            // Do not evict a large GPU-authored range merely because the next
            // shader binds this descriptor slot to another address. Retain it
            // as an address-keyed allocation while capacity remains; a later
            // shader can bind it from any slot without a guest round trip.
            if (recycle_index) |index| {
                if (self.guest_buffers.items[index].gpu_dirty and
                    self.guest_buffers.items.len < maximum_guest_buffers)
                {
                    recycle_index = null;
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
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
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
        var analysis = try gpu.shader_analysis.decode(self.allocator, reader, program_address, 4096);
        defer analysis.deinit(self.allocator);
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
        var analysis = try gpu.shader_analysis.decode(self.allocator, reader, program_address, 4096);
        defer analysis.deinit(self.allocator);
        if (try self.tryEmulateGdsInitialization(
            memory,
            state,
            &analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateBufferCopy(
            memory,
            state,
            &analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateImageStoreClear(
            memory,
            &bindings,
            reader,
            &analysis,
            system_registers,
            local_size,
            group_count,
        )) |report| return report;
        if (try self.tryEmulateVolumeBufferCopy(
            memory,
            &bindings,
            reader,
            &analysis,
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
        const specialized_scalar_prefix_end = scalarPrefixEnd(&analysis);
        const scalar = gpu.scalar_provenance.evaluatePrefixUntil(reader, &bindings, specialized_scalar_prefix_end);
        var resources = try self.prepareComputeResources(
            &bindings,
            reader,
            &analysis,
            &scalar,
            specialized_scalar_prefix_end,
        );
        var module = analysis.translateSpirv(self.allocator, .{
            .stage = .compute,
            .local_size = local_size,
            .storage_buffers = resources.mappings[0..resources.mapping_count],
            .scalar_registers = resources.scalar_registers[0..resources.scalar_count],
            .compute_inputs = .{
                .workgroup_id_sgprs = system_registers.workgroup_id_sgprs,
                .threadgroup_size_sgpr = system_registers.threadgroup_size_sgpr,
                .local_invocation_id_components = system_registers.local_invocation_id_components,
            },
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
        const report = try self.dispatchSpirv(module.words, group_count);
        try self.commitComputeWrites(memory, &resources);
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
    ) anyerror!ComputeResources {
        var result = ComputeResources{};
        result.specialized_scalar_prefix_end = specialized_scalar_prefix_end;
        const vertex_table = if (bindings.stage != .compute)
            (gpu.VertexBindings.capture(bindings, reader) catch null)
        else
            null;
        var vertex_attribute_index: usize = 0;
        for (scalar.registers, 0..) |value, index| {
            if (!value.known) continue;
            result.scalar_registers[result.scalar_count] = .{ .register = @intCast(index), .value = value.value };
            result.scalar_count += 1;
        }

        // Preserve the AGC slot number whenever possible. This makes the host
        // descriptor table stable across shaders that share one SRT layout.
        var iterator = bindings.iterator(reader, .constant_buffer);
        while (try iterator.next()) |binding| {
            const descriptor = binding.descriptor.constant_buffer;
            if (descriptor.isNull() or descriptor.size_bytes == 0) continue;
            const size = std.math.cast(usize, descriptor.size_bytes) orelse return Error.GuestBufferTooLarge;
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
            if (bindings.stage == .compute) if (result.mappingForSgpr(resource_sgpr)) |descriptor_index| {
                if (is_store) result.writable[descriptor_index] = true;
                continue;
            };

            var vertex_attribute: ?gpu.VertexAttribute = null;
            if (bindings.stage != .compute and inst.family != .smem and !is_store) {
                if (vertex_table) |table| {
                    if (vertex_attribute_index < table.attribute_count) {
                        vertex_attribute = table.attributes[vertex_attribute_index];
                        vertex_attribute_index += 1;
                    }
                }
            }
            const descriptor = (if (vertex_attribute) |attribute|
                takePlausibleBufferDescriptor(attribute.buffer)
            else
                null) orelse try resolveComputeBufferDescriptor(
                bindings,
                reader,
                scalar,
                resource_sgpr,
            ) orelse {
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
            result.mappings[result.mapping_count] = .{
                .resource_sgpr = resource_sgpr,
                .descriptor_index = descriptor_index,
                .instruction_pc = if (bindings.stage == .compute) null else inst.pc,
                .soffset_value = if (vertex_attribute) |attribute| attribute.offset_bytes else null,
                .use_vertex_index = vertex_attribute != null,
                .stride = descriptor.stride,
                .swizzled = descriptor.swizzle_enabled,
                .index_stride = descriptor.index_stride,
                .add_thread_id = descriptor.add_thread_id,
                // The descriptor already says how far the buffer goes, so the
                // shader can be held to it instead of being trusted to stay
                // inside on its own.
                .extent_bytes = std.math.cast(u32, descriptor.size_bytes),
            };
            result.mapping_count += 1;
            if (is_store) result.writable[descriptor_index] = true;
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
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));

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

    fn createGraphicsRenderPass(self: *Renderer, preserve_color: bool) Error!vk.RenderPass {
        const attachment = vk.AttachmentDescription{
            .format = vk.format_r8g8b8a8_unorm,
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
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{};
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
        const info = vk.GraphicsPipelineCreateInfo{
            .stage_count = stages.len,
            .stages = &stages,
            .vertex_input_state = &vertex_input,
            .input_assembly_state = &input_assembly,
            .viewport_state = &viewport_state,
            .rasterization_state = &rasterization,
            .multisample_state = &multisample,
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

    fn getGraphicsPipeline(
        self: *Renderer,
        render_pass: vk.RenderPass,
        pipeline_state: GraphicsPipelineState,
        vertex_words: []const u32,
        fragment_words: []const u32,
    ) (Error || std.mem.Allocator.Error)!vk.Pipeline {
        self.graphics_pipeline_sequence +%= 1;
        const state_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&pipeline_state));
        const vertex_hash = std.hash.Wyhash.hash(state_hash, std.mem.sliceAsBytes(vertex_words));
        const hash = std.hash.Wyhash.hash(vertex_hash, std.mem.sliceAsBytes(fragment_words));
        for (self.graphics_pipelines.items) |*entry| {
            if (entry.hash == hash and
                std.mem.eql(u8, std.mem.asBytes(&entry.state), std.mem.asBytes(&pipeline_state)) and
                std.mem.eql(u32, entry.vertex_words, vertex_words) and
                std.mem.eql(u32, entry.fragment_words, fragment_words))
            {
                self.graphics_pipeline_cache_hits += 1;
                entry.last_used_sequence = self.graphics_pipeline_sequence;
                return entry.pipeline;
            }
        }
        const owned_vertex = try self.allocator.dupe(u32, vertex_words);
        errdefer self.allocator.free(owned_vertex);
        const owned_fragment = try self.allocator.dupe(u32, fragment_words);
        errdefer self.allocator.free(owned_fragment);
        const pipeline = try self.createGraphicsPipeline(render_pass, pipeline_state, vertex_words, fragment_words);
        errdefer self.device_functions.destroy_pipeline(self.device, pipeline, null);
        const replacement = GraphicsPipelineEntry{
            .hash = hash,
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
            a.descriptor.tile_mode == b.descriptor.tile_mode and
            a.descriptor.samples_log2 == b.descriptor.samples_log2 and
            a.descriptor.fragments_log2 == b.descriptor.fragments_log2 and
            a.descriptor.base_array_slice == b.descriptor.base_array_slice and
            a.descriptor.mip_level == b.descriptor.mip_level and
            a.layout.required_source_bytes == b.layout.required_source_bytes and
            a.layout.staging_bytes == b.layout.staging_bytes;
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
    fn colorTargetFastClearTexel(self: *Renderer, target: GuestColorTarget) anyerror!?[4]u8 {
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
        return dccClearTexel(code, descriptor);
    }

    fn reportFastClearSeed(self: *Renderer, target: GuestColorTarget, texel: [4]u8) void {
        if (self.reported_fast_clear_seeds >= 4 and !log_verbose_gpu) return;
        self.reported_fast_clear_seeds += 1;
        std.debug.print(
            "[vulkan dcb] dcc fast-clear target @0x{x} {d}x{d} key@0x{x} rgba={d},{d},{d},{d}\n",
            .{
                target.descriptor.address,
                target.descriptor.width,
                target.descriptor.height,
                target.descriptor.dcc_address,
                texel[0],
                texel[1],
                texel[2],
                texel[3],
            },
        );
    }

    fn createCachedRenderTarget(self: *Renderer, target: GuestColorTarget) anyerror!CachedRenderTarget {
        const frame_bytes = try colorTargetFrameBytes(target);
        const image = try self.createImage(
            target.descriptor.width,
            target.descriptor.height,
            vk.format_r8g8b8a8_unorm,
            vk.image_usage_color_attachment_bit |
                vk.image_usage_transfer_src_bit |
                vk.image_usage_transfer_dst_bit,
        );
        errdefer self.destroyImage(image);

        const view_info = vk.ImageViewCreateInfo{
            .image = image.handle,
            .format = vk.format_r8g8b8a8_unorm,
            .subresource_range = .{ .aspect_mask = vk.image_aspect_color_bit },
        };
        var view: vk.ImageView = 0;
        if (self.device_functions.create_image_view(self.device, &view_info, null, &view) != vk.success) {
            return Error.ImageViewCreationFailed;
        }
        errdefer self.device_functions.destroy_image_view(self.device, view, null);

        const render_pass = try self.createGraphicsRenderPass(true);
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
        self.device_functions.destroy_framebuffer(self.device, target.framebuffer, null);
        self.device_functions.destroy_render_pass(self.device, target.render_pass, null);
        self.device_functions.destroy_image_view(self.device, target.view, null);
        self.destroyBuffer(target.readback);
        self.destroyImage(target.image);
    }

    fn acquireRenderTarget(self: *Renderer, target: GuestColorTarget) anyerror!usize {
        for (self.render_targets.items, 0..) |*cached, index| {
            if (!sameRenderTarget(cached.target, target)) continue;
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
        if (!snapshot.initialized or snapshot.gpu_generation == snapshot.host_generation) return;
        const frame_bytes = try colorTargetFrameBytes(snapshot.target);

        const command_buffer = try self.beginOneShot();
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
        const to_transfer = vk.ImageMemoryBarrier{
            .source_access_mask = vk.access_color_attachment_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .old_layout = vk.image_layout_color_attachment_optimal,
            .new_layout = vk.image_layout_transfer_src_optimal,
            .image = snapshot.image.handle,
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
        if (snapshot.target.descriptor.force_destination_alpha_one) forceDestinationAlphaOne(frame);
        try self.recordGuestColorTarget(snapshot.target, frame);
        self.render_targets.items[index].host_generation = snapshot.gpu_generation;

        var colored: u32 = 0;
        var pixel: usize = 0;
        while (pixel < frame.len) : (pixel += 4) {
            if (frame[pixel] != 0 or frame[pixel + 1] != 0 or frame[pixel + 2] != 0) colored += 1;
        }
        self.graphics_probe_colored_pixels = colored;
        if (self.frame_dumps == 0 and colored != 0) {
            dumpFramePpm("out\\first-frame.ppm", snapshot.target.descriptor.width, snapshot.target.descriptor.height, frame);
            self.frame_dumps += 1;
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

    fn drawPersistentGraphicsShaders(
        self: *Renderer,
        vertex_words: []const u32,
        fragment_words: []const u32,
        pipeline_state: GraphicsPipelineState,
        target: GuestColorTarget,
        bind_graphics_descriptors: bool,
        draw: GuestDraw,
    ) anyerror!void {
        const target_index = try self.acquireRenderTarget(target);
        const cached_snapshot = self.render_targets.items[target_index];
        const frame_bytes = try colorTargetFrameBytes(target);

        var initial_upload: ?OwnedBuffer = null;
        defer if (initial_upload) |buffer| self.destroyBuffer(buffer);
        if (!cached_snapshot.initialized) {
            const frame = try self.allocator.alloc(u8, frame_bytes);
            defer self.allocator.free(frame);
            const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
            const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
            if (try self.colorTargetFastClearTexel(target)) |texel| {
                fillRgba8(frame, texel);
                self.reportFastClearSeed(target, texel);
            } else {
                try target.layout.stage(reader, target.descriptor.address, frame);
            }
            initial_upload = try self.createBuffer(
                frame_bytes,
                vk.buffer_usage_transfer_src_bit,
                vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
            );
            try self.writeMapped(initial_upload.?, frame);
            self.frame_profile.upload_bytes += frame_bytes;
            self.frame_profile.target_upload_bytes += frame_bytes;
        }

        const pipeline = try self.getGraphicsPipeline(
            cached_snapshot.render_pass,
            pipeline_state,
            vertex_words,
            fragment_words,
        );
        const command_buffer = try self.beginOneShot();
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));

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

        const begin_info = vk.RenderPassBeginInfo{
            .render_pass = cached_snapshot.render_pass,
            .framebuffer = cached_snapshot.framebuffer,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = pipeline_state.width, .height = pipeline_state.height },
            },
            .clear_value_count = 0,
            .clear_values = undefined,
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

        self.render_target_sequence +%= 1;
        const cached = &self.render_targets.items[target_index];
        cached.initialized = true;
        cached.gpu_generation +%= 1;
        cached.last_used_sequence = self.render_target_sequence;
        self.latest_render_target_index = target_index;
    }

    fn drawGraphicsShaders(
        self: *Renderer,
        vertex_words: []const u32,
        fragment_words: []const u32,
        pipeline_state: GraphicsPipelineState,
        guest_target: ?GuestColorTarget,
        bind_graphics_descriptors: bool,
        validate_diagnostic_color: bool,
        draw: GuestDraw,
    ) anyerror!void {
        if (guest_target) |target| {
            return self.drawPersistentGraphicsShaders(
                vertex_words,
                fragment_words,
                pipeline_state,
                target,
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

        const render_pass = try self.createGraphicsRenderPass(guest_target != null);
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
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
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
        self.guest_color_target_writes += 1;
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
            GraphicsPipelineState.default(graphics_probe_width, graphics_probe_height),
            null,
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
        // Depth and multi-MRT are ignored on this first host path: only colour
        // target 0 is rendered. Many title draws enable depth; rejecting them
        // would drop the whole colour path.
        if (render_state.depth_control.test_enabled or render_state.depth_control.write_enabled or
            (target_override == null and render_state.active_color_count != 1))
        {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw: ignoring depth/mrt extras (colors={d} depth_test={any} depth_write={any})\n",
                .{
                    render_state.active_color_count,
                    render_state.depth_control.test_enabled,
                    render_state.depth_control.write_enabled,
                },
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
        const descriptor = target_descriptor orelse return Error.MissingColorTarget;
        if (descriptor.samples_log2 != 0 or descriptor.fragments_log2 != 0) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw rejected: MSAA color target samples={d} frags={d}\n",
                .{ descriptor.samples_log2, descriptor.fragments_log2 },
            );
            return Error.UnsupportedColorTarget;
        }
        // DCC/CMASK/FMASK are ignored on the first path: the surface is staged
        // as raw tiles. Compressed contents may look wrong until a decompressor
        // exists, but rejecting compressed targets blocks typical title draws.
        if (descriptor.dcc_enabled or descriptor.cmask_fast_clear or descriptor.fmask_compression) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw: ignoring compression flags dcc={any} cmask={any} fmask={any} fmt={d}\n",
                .{
                    descriptor.dcc_enabled,
                    descriptor.cmask_fast_clear,
                    descriptor.fmask_compression,
                    descriptor.format,
                },
            );
        }
        if (descriptor.format != 10) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] draw: treating color format {d} as 32bpp RGBA\n",
                .{descriptor.format},
            );
        }
        const layout = try gpu.SurfaceLayout.fromColorTarget(descriptor);
        if (layout.layers != 1 or layout.block.bytes_per_element != 4) return Error.UnsupportedColorTarget;
        const pipeline_state = try guestGraphicsState(&render_state, descriptor);
        const target = GuestColorTarget{ .descriptor = descriptor, .layout = layout };
        const vertex_address = vertex_stage.programAddress(state) orelse {
            return Error.MissingGraphicsProgram;
        };
        const fragment_address = gpu.resources.ShaderStage.pixel.programAddress(state) orelse {
            return Error.MissingGraphicsProgram;
        };
        const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
        var vertex_analysis = try gpu.shader_analysis.decode(self.allocator, reader, vertex_address, 4096);
        defer vertex_analysis.deinit(self.allocator);
        var fragment_analysis = try gpu.shader_analysis.decode(self.allocator, reader, fragment_address, 4096);
        defer fragment_analysis.deinit(self.allocator);
        if (self.reported_interface_pairs < 2 and
            (self.last_interface_vertex_address != vertex_address or
                self.last_interface_fragment_address != fragment_address))
        {
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
            std.debug.print(
                "[vulkan dcb] shader interface VS=0x{x} exports=0x{x} params=0x{x} PS=0x{x} attrs=0x{x}\n",
                .{ vertex_address, vertex_export_mask, vertex_parameter_mask, fragment_address, fragment_attribute_mask },
            );
            self.last_interface_vertex_address = vertex_address;
            self.last_interface_fragment_address = fragment_address;
            self.reported_interface_pairs += 1;
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
        var graphics_resources = try self.prepareGraphicsResources(
            &fragment_bindings,
            reader,
            &fragment_analysis,
        );
        defer graphics_resources.deinit(self);

        // Full scalar evaluation (not only the straight prolog cut): vertex
        // programs interleave SMEM loads after a few VALU ops, and those SGPRs
        // must be constants in SPIR-V rather than live s_load (no host pointer
        // load path yet). Specialize every known SGPR across the whole program.
        const vertex_scalar = gpu.scalar_provenance.evaluatePrefix(reader, &vertex_bindings);
        const vertex_scalar_end: u32 = 0x0010_0000;
        var vertex_scalar_regs: [128]gpu.ShaderSpirvScalarRegister = undefined;
        var vertex_scalar_count = collectKnownScalars(&vertex_scalar, &vertex_scalar_regs);
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
            &vertex_analysis,
            &vertex_scalar_regs,
            vertex_scalar_count,
            &vertex_scalar_mut,
        );

        const fragment_scalar = gpu.scalar_provenance.evaluatePrefix(reader, &fragment_bindings);
        const fragment_scalar_end: u32 = 0x0010_0000;
        var fragment_scalar_regs: [128]gpu.ShaderSpirvScalarRegister = undefined;
        var fragment_scalar_count = collectKnownScalars(&fragment_scalar, &fragment_scalar_regs);
        // Unity PS loads a float4 scale via s_buffer into s16..; when the
        // constant buffer could not be resolved at all those registers stay
        // unknown and every v_mul after the sample would write black. Seed 1.0
        // for exactly those, so a missing constant buffer is an identity scale.
        fragment_scalar_count = ensureIdentityFragmentScale(
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
            &vertex_analysis,
            &vertex_scalar_mut,
            vertex_scalar_end,
        ) catch |err| blk: {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] vertex storage incomplete: {s}; translating without buffers\n",
                .{@errorName(err)},
            );
            break :blk ComputeResources{};
        };
        // prepareComputeResources soft-skips missing V#s; rebuild its scalar
        // list from the seeded specialization so SPIR-V and staging agree.
        if (vertex_storage.scalar_count == 0 and vertex_scalar_count != 0) {
            // already filled from evaluation; merge seeds into result scalars
        }
        for (vertex_scalar_regs[0..vertex_scalar_count]) |seeded| {
            var found = false;
            for (vertex_storage.scalar_registers[0..vertex_storage.scalar_count]) |*entry| {
                if (entry.register == seeded.register) {
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
                    "  pc={any} V#s{d} slot={d} addr=0x{x} size=0x{x} stride={d} soffset={any}\n",
                    .{
                        mapping.instruction_pc,
                        mapping.resource_sgpr,
                        mapping.descriptor_index,
                        vertex_storage.addresses[slot],
                        vertex_storage.sizes[slot],
                        mapping.stride,
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

        var fragment_module = fragment_analysis.translateSpirv(self.allocator, .{
            .stage = .fragment,
            .sampled_images = graphics_resources.mappings[0..graphics_resources.mapping_count],
            .descriptor_array_length = maximum_storage_descriptors,
            .scalar_registers = fragment_scalar_regs[0..fragment_scalar_count],
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
                dumpShaderHead(&fragment_analysis, 16);
                dumpScalarRegisters(fragment_scalar_regs[0..fragment_scalar_count]);
            }
            return err;
        };
        defer fragment_module.deinit(self.allocator);

        // Prefer the guest VS whenever at least one attribute V# mapped. AGC
        // commonly places it at s0 or s8 as well as s4; requiring one fixed
        // SGPR was what collapsed whole scenes onto the probe triangle.
        const try_guest_vs = vertex_storage.mapping_count != 0;
        if (try_guest_vs) {
            if (vertex_analysis.translateSpirv(self.allocator, .{
                .stage = .vertex,
                .vertex_index_vgpr = 0,
                .scalar_registers = vertex_scalar_regs[0..vertex_scalar_count],
                .specialized_scalar_prefix_end = vertex_scalar_end,
                .storage_buffers = vertex_storage.mappings[0..vertex_storage.mapping_count],
                .descriptor_array_length = maximum_storage_descriptors,
            })) |vertex_module_owned| {
                var vertex_module = vertex_module_owned;
                defer vertex_module.deinit(self.allocator);
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
                    fragment_module.words,
                    pipeline_state,
                    target,
                    true,
                    false,
                    draw,
                );
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
                    dumpShaderHead(&vertex_analysis, vertex_analysis.program.instructions.items.len);
                }
            }
        } else {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] using probe VS + guest PS (no attr V# s4); storage_maps={d} sampled={d}\n",
                .{ vertex_storage.mapping_count, graphics_resources.mapping_count },
            );
        }
        try self.drawGraphicsShaders(
            &graphics_probe_vertex_spirv,
            fragment_module.words,
            pipeline_state,
            target,
            graphics_resources.mapping_count != 0,
            false,
            .{ .vertex_count = 3, .instance_count = 1 },
        );
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
            // Prefer T#/S# already in USER_DATA; otherwise take the next SRT
            // texture/sampler slots in declaration order (common AGC layout).
            const image_descriptor = (try bindings.inlineImageDescriptor(inst.src1.reg)) orelse
                (try resolveSrtImageDescriptor(bindings, reader, result.mapping_count)) orelse {
                std.debug.print(
                    "[vulkan dcb] sampled image missing for s{d} (user_data={d} srt={any})\n",
                    .{ inst.src1.reg, bindings.user_data_count, bindings.srt_address != null },
                );
                return Error.UnsupportedSampledImage;
            };
            const sampler_descriptor = (try bindings.inlineSamplerDescriptor(inst.src2.reg)) orelse
                (try resolveSrtSamplerDescriptor(bindings, reader, result.mapping_count)) orelse {
                std.debug.print(
                    "[vulkan dcb] sampler missing for s{d}\n",
                    .{inst.src2.reg},
                );
                return Error.UnsupportedSampledImage;
            };
            const descriptor_index: u32 = @intCast(result.mapping_count);
            const image = self.stageSampledImage(image_descriptor, sampler_descriptor, descriptor_index) catch |err| {
                std.debug.print(
                    "[vulkan dcb] stageSampledImage failed: {s} addr=0x{x} {d}x{d} fmt={d}\n",
                    .{
                        @errorName(err),
                        image_descriptor.address,
                        image_descriptor.width,
                        image_descriptor.height,
                        image_descriptor.unified_format,
                    },
                );
                return err;
            };
            result.images[result.image_count] = image;
            result.image_count += 1;
            result.mappings[result.mapping_count] = .{
                .resource_sgpr = inst.src1.reg,
                .sampler_sgpr = inst.src2.reg,
                .descriptor_index = descriptor_index,
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

    fn createImage(self: *Renderer, width: u32, height: u32, format: u32, usage: vk.Flags) Error!OwnedImage {
        const create_info = vk.ImageCreateInfo{
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
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
    ) void {
        const image_info = vk.DescriptorImageInfo{
            .sampler = sampler,
            .image_view = view,
            .image_layout = vk.image_layout_shader_read_only_optimal,
        };
        const write = vk.WriteDescriptorSet{
            .destination_set = self.descriptor_set,
            .destination_binding = 1,
            .destination_array_element = descriptor_index,
            .descriptor_count = 1,
            .descriptor_type = vk.descriptor_type_combined_image_sampler,
            .image_info = @ptrCast(&image_info),
            .buffer_info = null,
        };
        self.device_functions.update_descriptor_sets(self.device, 1, @ptrCast(&write), 0, null);
    }

    fn stageSampledImage(
        self: *Renderer,
        descriptor: gpu.resources.ImageDescriptor,
        sampler_descriptor: gpu.resources.SamplerDescriptor,
        descriptor_index: u32,
    ) anyerror!PreparedSampledImage {
        if (descriptor.unified_format != 56) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image format {d} (want 56/RGBA8)\n",
                .{descriptor.unified_format},
            );
            return Error.UnsupportedSampledImage;
        }
        if (descriptor.image_type != .color_2d) {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image type {s} (want color_2d)\n",
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
        const layout = try gpu.SurfaceLayout.fromImage(descriptor);
        if (layout.layers != 1 or layout.block.bytes_per_element != 4 or
            layout.staging_bytes == 0 or layout.staging_bytes > maximum_frame_bytes)
        {
            if (log_verbose_gpu) std.debug.print(
                "[vulkan dcb] sampled image layout rejected layers={d} bpp={d} stage=0x{x}\n",
                .{ layout.layers, layout.block.bytes_per_element, layout.staging_bytes },
            );
            return Error.UnsupportedSampledImage;
        }
        const byte_count = std.math.cast(usize, layout.staging_bytes) orelse return Error.UnsupportedSampledImage;
        const probe_span = std.math.cast(usize, layout.required_source_bytes) orelse 0;
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

        const content_hash = hashGuestMemoryRange(memory, descriptor.address, probe_span);
        const state_hash = sampledImageStateHash(descriptor, sampler_descriptor);
        const source_generation = self.sampledSourceGeneration(descriptor.address);

        var cache_hit_idx: ?usize = null;
        for (self.sampled_image_cache.items, 0..) |*item, idx| {
            if (item.guest_address == descriptor.address and
                item.width == descriptor.width and
                item.height == descriptor.height and
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
            self.updateSampledImageDescriptor(descriptor_index, item.view, item.sampler);
            return .{ .image = item.image, .view = item.view, .sampler = item.sampler };
        }
        self.texture_cache_misses += 1;
        if (self.texture_cache_misses == 1) {
            std.debug.print("[vulkan dcb] texture cache miss: first @0x{x} hash={x}\n", .{ descriptor.address, content_hash });
        }

        const linear = try self.allocator.alloc(u8, byte_count);
        defer self.allocator.free(linear);
        const reader = gpu.ShaderMemoryReader{ .context = memory.context, .read_fn = memory.read };
        if (layout.block.tile_mode.isLinear()) {
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
        const nonzero = countNonzeroRgba(linear);
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
        const raw_probe_span = std.math.cast(usize, layout.required_source_bytes) orelse 0;
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
        if (log_verbose_gpu) std.debug.print(
            "[vulkan dcb] staged sample {d}x{d} tile={s} addr=0x{x} nonzero_texels={d}/{d} raw_probe_nz={d} hits={d} first_rgba=({d},{d},{d},{d})\n",
            .{
                descriptor.width,
                descriptor.height,
                @tagName(descriptor.tile_mode),
                descriptor.address,
                nonzero,
                if (byte_count >= 4) byte_count / 4 else 0,
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
            const deep_span: u64 = @max(raw_probe_span, @as(u64, descriptor.width) * descriptor.height * 4 * 2);
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
        const image_format = sampledImageFormat(sampler_descriptor.force_srgb);
        const components = try sampledImageComponents(descriptor.dst_select);
        const upload = try self.createBuffer(
            byte_count,
            vk.buffer_usage_transfer_src_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(upload);
        try self.writeMapped(upload, linear);
        const image = try self.createImage(
            descriptor.width,
            descriptor.height,
            image_format,
            vk.image_usage_transfer_dst_bit | vk.image_usage_sampled_bit,
        );
        errdefer self.destroyImage(image);

        const command_buffer = try self.beginOneShot();
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
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
            .image_extent = .{ .width = descriptor.width, .height = descriptor.height, .depth = 1 },
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
            vk.pipeline_stage_fragment_shader_bit,
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
        self.updateSampledImageDescriptor(descriptor_index, view, sampler);
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
        if (descriptor.magnification_filter > 1 or descriptor.minification_filter > 1 or
            descriptor.mip_filter > 1 or descriptor.unnormalized_coordinates)
        {
            return Error.UnsupportedSampledImage;
        }
        const info = vk.SamplerCreateInfo{
            .magnification_filter = descriptor.magnification_filter,
            .minification_filter = descriptor.minification_filter,
            .mipmap_mode = descriptor.mip_filter,
            .address_mode_u = try vulkanAddressMode(descriptor.clamp_x),
            .address_mode_v = try vulkanAddressMode(descriptor.clamp_y),
            .address_mode_w = try vulkanAddressMode(descriptor.clamp_z),
            .mip_lod_bias = descriptor.lod_bias,
            .minimum_lod = descriptor.minimum_lod,
            .maximum_lod = descriptor.maximum_lod,
        };
        var sampler: vk.Sampler = 0;
        if (self.device_functions.create_sampler(self.device, &info, null, &sampler) != vk.success) {
            return Error.SamplerCreationFailed;
        }
        return sampler;
    }

    fn vulkanAddressMode(mode: u8) Error!u32 {
        return switch (mode) {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 4,
            4 => 3,
            5 => 4,
            else => Error.UnsupportedSampledImage,
        };
    }

    fn beginOneShot(self: *Renderer) Error!vk.CommandBuffer {
        const allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = vk.command_buffer_level_primary,
            .command_buffer_count = 1,
        };
        var command_buffer: vk.CommandBuffer = undefined;
        if (self.device_functions.allocate_command_buffers(self.device, &allocate_info, @ptrCast(&command_buffer)) != vk.success) {
            return Error.CommandBufferAllocationFailed;
        }
        errdefer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
        const begin_info = vk.CommandBufferBeginInfo{ .flags = vk.command_buffer_usage_one_time_submit_bit };
        if (self.device_functions.begin_command_buffer(command_buffer, &begin_info) != vk.success) {
            return Error.CommandBufferBeginFailed;
        }
        return command_buffer;
    }

    fn submitOneShot(self: *Renderer, command_buffer: vk.CommandBuffer) Error!void {
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
        const memory = self.guest_memory orelse return false;
        return memory.read(memory.context, address, bytes);
    }

    fn dcbWrite(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = fromContext(context);
        self.flushGuestStorageRange(address, bytes.len) catch return false;
        const memory = self.guest_memory orelse return false;
        return memory.write(memory.context, address, bytes);
    }

    fn dcbAcquire(context: ?*anyopaque, _: gpu.state.AcquireMem) bool {
        const self = fromContext(context);
        self.acquire_callbacks += 1;
        // No device wait: every submission is fence-completed synchronously
        // before the executor reaches a synchronization packet, so the queue
        // is already idle and guest memory is current.
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

        return sink.present(sink.context, .{
            .pixels = self.guest_frame_scratch.items,
            .width = buffer.width,
            .height = buffer.height,
            .row_pitch_bytes = @intCast(row_bytes),
            .guest_address = buffer.address,
            .flip = flip,
        });
    }

    fn reportFrameProfile(self: *Renderer) void {
        const profile = self.frame_profile;
        const now = hostTimestampNs();
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
        }
        self.frame_profile.reset();
    }

    fn discardPendingTargetlessDraw(self: *Renderer) void {
        if (self.pending_targetless_draw) |pending| self.allocator.destroy(pending);
        self.pending_targetless_draw = null;
    }

    fn resolvePendingTargetlessDraw(self: *Renderer, buffer: DisplayBuffer) void {
        const pending = self.pending_targetless_draw orelse return;
        self.pending_targetless_draw = null;
        defer self.allocator.destroy(pending);
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
        self.drawGuestGraphics(&pending.state, pending.draw, pending.vertex_stage, target) catch |err| {
            self.last_draw_error = err;
            if (self.shouldReportDrawError(err)) {
                std.debug.print("[vulkan dcb] deferred display draw rejected: {s}\n", .{@errorName(err)});
            }
            return;
        };
        self.guest_graphics_draws += 1;
        self.translated_draws += 1;
        self.targetless_draws_resolved += 1;
        self.last_draw_error = null;
        if (self.targetless_draws_resolved == 1 or log_verbose_gpu) {
            std.debug.print(
                "[vulkan dcb] deferred display draw ok: target=0x{x} {d}x{d} tile={d}\n",
                .{ buffer.address, buffer.width, buffer.height, buffer.tiling_mode },
            );
        }
    }

    fn dcbFlip(context: ?*anyopaque, flip: gpu.state.Flip) bool {
        const self = fromContext(context);
        self.flip_callbacks += 1;
        defer self.reportFrameProfile();
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
            if (self.window_presentation != null and self.flip_callbacks != 8) {
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
        switch (self.flip_callbacks) {
            8, 16, 32, 64, 96, 128 => {
                var path_buffer: [64]u8 = undefined;
                const path: ?[:0]u8 = std.fmt.bufPrintZ(
                    &path_buffer,
                    "out\\frame-{d:0>4}.ppm",
                    .{self.flip_callbacks},
                ) catch null;
                if (path) |name| {
                    dumpFramePpm(name.ptr, cached.width, cached.height, cached.pixels.items);
                    std.debug.print(
                        "[vulkan dcb] dumped progress frame {d} ({d}x{d})\n",
                        .{ self.flip_callbacks, cached.width, cached.height },
                    );
                }
            },
            else => {},
        }
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
        const repeated = self.last_shader_failure_address == address and
            self.last_shader_failure_stage != null and
            self.last_shader_failure_stage.? == stage and
            self.last_shader_failure_error != null and
            self.last_shader_failure_error.? == err;
        self.last_shader_failure_address = address;
        self.last_shader_failure_stage = stage;
        self.last_shader_failure_error = err;
        return !repeated;
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
            if (render_state.active_color_count == 0) {
                const pending = self.pending_targetless_draw orelse self.allocator.create(PendingGuestDraw) catch |err| {
                    self.last_draw_error = err;
                    if (self.shouldReportDrawError(err)) {
                        std.debug.print("[vulkan dcb] targetless draw skipped: {s}\n", .{@errorName(err)});
                    }
                    return true;
                };
                pending.* = .{
                    .state = state.*,
                    .draw = draw,
                    .vertex_stage = vertex_stage.?,
                };
                self.pending_targetless_draw = pending;
                self.targetless_draws_deferred += 1;
                self.last_draw_error = null;
                if (self.targetless_draws_deferred == 1 or log_verbose_gpu) {
                    std.debug.print("[vulkan dcb] deferred targetless draw until display flip\n", .{});
                }
                return true;
            }
            self.discardPendingTargetlessDraw();
            self.drawGuestGraphics(state, draw, vertex_stage.?, null) catch |err| {
                self.last_draw_error = err;
                if (self.shouldReportDrawError(err)) std.debug.print("[vulkan dcb] draw rejected: {s}\n", .{@errorName(err)});
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
        if (gpu.resources.ShaderStage.compute.programAddress(state) == null) {
            self.last_dispatch_error = Error.MissingComputeProgram;
            // A reset/default-state packet may be followed by a dispatch that
            // has no executable program in the subset of state we retain.
            // Do not discard later graphics work and the frame's flip merely
            // because this one compute operation cannot be reproduced yet.
            std.debug.print("[vulkan dcb] dispatch skipped: {s}\n", .{@errorName(Error.MissingComputeProgram)});
            return true;
        }
        const local_size = [3]u32{
            computeLocalSize(state, 0x207),
            computeLocalSize(state, 0x208),
            computeLocalSize(state, 0x209),
        };
        _ = self.dispatchRdna2State(
            state,
            local_size,
            .{ packet.body[0], packet.body[1], packet.body[2] },
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

fn collectKnownScalars(
    scalar: *const gpu.ScalarEvaluation,
    out: []gpu.ShaderSpirvScalarRegister,
) usize {
    var count: usize = 0;
    for (scalar.registers, 0..) |value, index| {
        if (!value.known) continue;
        if (count >= out.len) break;
        out[count] = .{ .register = @intCast(index), .value = value.value };
        count += 1;
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
            if (entry.register == reg) {
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

fn sampledImageFormat(force_srgb: bool) u32 {
    return if (force_srgb) vk.format_r8g8b8a8_srgb else vk.format_r8g8b8a8_unorm;
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
        0x20 => if (descriptor.format == 10 and descriptor.number_type == 0 and descriptor.component_swap == 0) blk: {
            const word = descriptor.clear_words[0];
            break :blk .{
                @truncate(word),
                @truncate(word >> 8),
                @truncate(word >> 16),
                @truncate(word >> 24),
            };
        } else null,
        else => null,
    };
}

fn fillRgba8(linear: []u8, texel: [4]u8) void {
    var index: usize = 0;
    while (index + 3 < linear.len) : (index += 4) {
        linear[index..][0..4].* = texel;
    }
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
                "  pc=0x{x:0>4} exp target={d} en=0x{x} done={any} compr={any} src0={s}:{d}\n",
                .{
                    inst.pc,
                    inst.export_target,
                    inst.export_enable,
                    inst.export_done,
                    inst.export_compressed,
                    @tagName(inst.src0.kind),
                    inst.src0.reg,
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
                "  pc=0x{x:0>4} word=0x{x:0>8} {s} dst={s}:{d} src0={s}:{d} src1={s}:{d} src2={s}:{d}\n",
                .{
                    inst.pc,
                    inst.word,
                    inst.opcode.mnemonic(),
                    @tagName(inst.dst.kind),
                    inst.dst.reg,
                    @tagName(inst.src0.kind),
                    inst.src0.reg,
                    @tagName(inst.src1.kind),
                    inst.src1.reg,
                    @tagName(inst.src2.kind),
                    inst.src2.reg,
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

fn takePlausibleBufferDescriptor(descriptor: ?gpu.BufferDescriptor) ?gpu.BufferDescriptor {
    const value = descriptor orelse return null;
    return if (isPlausibleBufferDescriptor(value)) value else null;
}

/// Recovers a V# for a compute/graphics MUBUF/SMEM instruction.
///
/// Order of attempts:
/// 1. Specialized scalar prefix (what the SPIR-V specialization path sees).
/// 2. Full scalar prolog — recovers descriptors loaded after the specialized
///    cut or through a longer SMEM chain.
/// 3. V# already resident in USER_DATA (with capture base and with base=0 —
///    NGG seeds often land at s0 even when scalar_user_data_base=8).
/// 4. AGC vertex buffer table entry (graphics attribute path).
fn resolveComputeBufferDescriptor(
    bindings: *const gpu.ShaderBindings,
    reader: gpu.ShaderMemoryReader,
    specialized: *const gpu.ScalarEvaluation,
    resource_sgpr: u32,
) anyerror!?gpu.BufferDescriptor {
    if (takePlausibleBufferDescriptor(try scalarBufferDescriptor(specialized, resource_sgpr))) |descriptor| {
        return descriptor;
    }
    const full = gpu.scalar_provenance.evaluatePrefix(reader, bindings);
    if (takePlausibleBufferDescriptor(try scalarBufferDescriptor(&full, resource_sgpr))) |descriptor| {
        return descriptor;
    }
    if (takePlausibleBufferDescriptor(try bindings.inlineBufferDescriptor(resource_sgpr))) |descriptor| {
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
        std.debug.print(
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
                if (entry.register == reg) {
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
    try std.testing.expectEqual(vk.format_r8g8b8a8_unorm, sampledImageFormat(false));
    try std.testing.expectEqual(vk.format_r8g8b8a8_srgb, sampledImageFormat(true));

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
