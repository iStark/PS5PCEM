// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Headless Vulkan renderer foundation.
//!
//! This owns the host instance, device, queue and command pool while exposing
//! the existing API-neutral DCB callback boundary. Supported direct compute
//! work crosses RDNA2 decode, ShaderBindings capture, storage-buffer lowering
//! and SPIR-V pipeline caching. An opt-in diagnostic graphics probe crosses the
//! real DCB draw callback, render pass, rasterization and image readback path;
//! guest vertex/pixel lowering remains separate. The smoke path proves queue
//! submission, descriptor arrays, staging, device-local memory and readback.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const vk = @import("api.zig");

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
    GraphicsProbeReadbackMismatch,
};

pub const Options = struct {
    enable_validation: bool = builtin.mode == .Debug,
    /// Diagnostic-only fixed shaders used to prove the DCB graphics submission
    /// and color-target path before guest vertex/pixel lowering is connected.
    enable_graphics_probe: bool = false,
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
    map_memory: vk.PfnMapMemory,
    unmap_memory: vk.PfnUnmapMemory,
    create_shader_module: vk.PfnCreateShaderModule,
    destroy_shader_module: vk.PfnDestroyShaderModule,
    create_pipeline_cache: vk.PfnCreatePipelineCache,
    destroy_pipeline_cache: vk.PfnDestroyPipelineCache,
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
    cmd_copy_buffer: vk.PfnCmdCopyBuffer,
    cmd_copy_image_to_buffer: vk.PfnCmdCopyImageToBuffer,
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
            .map_memory = try deviceProc(get_proc, device, vk.PfnMapMemory, "vkMapMemory"),
            .unmap_memory = try deviceProc(get_proc, device, vk.PfnUnmapMemory, "vkUnmapMemory"),
            .create_shader_module = try deviceProc(get_proc, device, vk.PfnCreateShaderModule, "vkCreateShaderModule"),
            .destroy_shader_module = try deviceProc(get_proc, device, vk.PfnDestroyShaderModule, "vkDestroyShaderModule"),
            .create_pipeline_cache = try deviceProc(get_proc, device, vk.PfnCreatePipelineCache, "vkCreatePipelineCache"),
            .destroy_pipeline_cache = try deviceProc(get_proc, device, vk.PfnDestroyPipelineCache, "vkDestroyPipelineCache"),
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
            .cmd_copy_buffer = try deviceProc(get_proc, device, vk.PfnCmdCopyBuffer, "vkCmdCopyBuffer"),
            .cmd_copy_image_to_buffer = try deviceProc(get_proc, device, vk.PfnCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer"),
            .cmd_pipeline_barrier = try deviceProc(get_proc, device, vk.PfnCmdPipelineBarrier, "vkCmdPipelineBarrier"),
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

const maximum_guest_buffers = 256;
pub const maximum_storage_descriptors = 64;
const maximum_compute_pipelines = 256;
const maximum_graphics_pipelines = 256;
const maximum_staged_buffer_bytes = 128 * 1024 * 1024;

const GuestBufferEntry = struct {
    guest_address: u64,
    size: vk.DeviceSize,
    upload: OwnedBuffer,
    device_local: OwnedBuffer,
};

const ComputePipelineEntry = struct {
    hash: u64,
    words: []u32,
    shader: vk.ShaderModule,
    pipeline: vk.Pipeline,
};

const GraphicsPipelineEntry = struct {
    hash: u64,
    vertex_words: []u32,
    fragment_words: []u32,
    pipeline: vk.Pipeline,
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
    guest_buffers: std.ArrayList(GuestBufferEntry) = .empty,
    compute_pipelines: std.ArrayList(ComputePipelineEntry) = .empty,
    graphics_pipelines: std.ArrayList(GraphicsPipelineEntry) = .empty,
    active_descriptor_set: ?vk.DescriptorSet = null,
    draw_callbacks: u64 = 0,
    translated_draws: u64 = 0,
    guest_graphics_draws: u64 = 0,
    graphics_probe_colored_pixels: u32 = 0,
    graphics_probe_frame: [graphics_probe_bytes]u8 = @splat(0),
    dispatch_callbacks: u64 = 0,
    translated_dispatches: u64 = 0,
    buffer_cache_hits: u64 = 0,
    buffer_cache_misses: u64 = 0,
    buffer_uploads: u64 = 0,
    pipeline_cache_hits: u64 = 0,
    pipeline_cache_misses: u64 = 0,
    graphics_pipeline_cache_hits: u64 = 0,
    graphics_pipeline_cache_misses: u64 = 0,
    last_dispatch_error: ?anyerror = null,
    last_draw_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) (Error || std.mem.Allocator.Error)!Renderer {
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
            .enabled_extension_count = 0,
            .enabled_extension_names = null,
        };
        const create_instance = try loader.global(vk.PfnCreateInstance, "vkCreateInstance");
        var maybe_instance: ?vk.Instance = null;
        if (create_instance(&instance_info, null, &maybe_instance) != vk.success) return Error.InstanceCreationFailed;
        const instance_handle = maybe_instance orelse return Error.InstanceCreationFailed;
        const instance_functions = try InstanceFunctions.load(&loader, instance_handle);
        errdefer instance_functions.destroy_instance(instance_handle, null);

        const candidate = try choosePhysicalDevice(allocator, instance_handle, &instance_functions);
        const queue_priority: f32 = 1.0;
        const queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = candidate.queue_family_index,
            .queue_count = 1,
            .queue_priorities = @ptrCast(&queue_priority),
        };
        const device_info = vk.DeviceCreateInfo{
            .queue_create_info_count = 1,
            .queue_create_infos = @ptrCast(&queue_info),
        };
        var maybe_device: ?vk.Device = null;
        if (instance_functions.create_device(candidate.physical_device, &device_info, null, &maybe_device) != vk.success) {
            return Error.DeviceCreationFailed;
        }
        const device = maybe_device orelse return Error.DeviceCreationFailed;
        const device_functions = try DeviceFunctions.load(instance_functions.get_device_proc_addr, device);
        errdefer device_functions.destroy_device(device, null);

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

        const storage_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = vk.descriptor_type_storage_buffer,
            .descriptor_count = maximum_storage_descriptors,
            .stage_flags = vk.shader_stage_compute_bit,
        };
        const descriptor_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 1,
            .bindings = @ptrCast(&storage_binding),
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
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .max_sets = 1,
            .pool_size_count = 1,
            .pool_sizes = @ptrCast(&pool_size),
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

        const pipeline_cache_info = vk.PipelineCacheCreateInfo{};
        var driver_pipeline_cache: vk.PipelineCache = 0;
        if (device_functions.create_pipeline_cache(device, &pipeline_cache_info, null, &driver_pipeline_cache) != vk.success) {
            return Error.PipelineCacheCreationFailed;
        }
        errdefer device_functions.destroy_pipeline_cache(device, driver_pipeline_cache, null);

        var memory_properties: vk.PhysicalDeviceMemoryProperties = undefined;
        instance_functions.get_memory_properties(candidate.physical_device, &memory_properties);

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
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.device_functions.device_wait_idle(self.device);
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
        for (self.guest_buffers.items) |entry| {
            self.destroyBuffer(entry.device_local);
            self.destroyBuffer(entry.upload);
        }
        self.guest_buffers.deinit(self.allocator);
        self.device_functions.destroy_pipeline_cache(self.device, self.driver_pipeline_cache, null);
        self.device_functions.destroy_pipeline_layout(self.device, self.compute_pipeline_layout, null);
        self.device_functions.destroy_descriptor_pool(self.device, self.descriptor_pool, null);
        self.device_functions.destroy_descriptor_set_layout(self.device, self.descriptor_set_layout, null);
        self.device_functions.destroy_command_pool(self.device, self.command_pool, null);
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

    /// Reuses host/device allocations for an exact guest range while uploading
    /// current guest bytes on every call. Allocation identity is cached; guest
    /// memory is never assumed immutable between submissions.
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
        if (descriptor_index >= maximum_storage_descriptors) return Error.InvalidStorageDescriptor;
        if (size == 0) return Error.GuestMemoryReadFailed;
        if (size > maximum_staged_buffer_bytes) return Error.GuestBufferTooLarge;
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;

        var entry_index: ?usize = null;
        for (self.guest_buffers.items, 0..) |entry, index| {
            if (entry.guest_address == guest_address and entry.size == size) {
                entry_index = index;
                break;
            }
        }
        const cache_hit = entry_index != null;
        if (entry_index == null) {
            if (self.guest_buffers.items.len >= maximum_guest_buffers) return Error.GuestBufferCacheFull;
            try self.guest_buffers.ensureUnusedCapacity(self.allocator, 1);
            const upload = try self.createBuffer(
                size,
                vk.buffer_usage_transfer_src_bit,
                vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
            );
            errdefer self.destroyBuffer(upload);
            const device_local = try self.createBuffer(
                size,
                vk.buffer_usage_transfer_src_bit | vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_storage_buffer_bit,
                0x0000_0001,
            );
            errdefer self.destroyBuffer(device_local);
            self.guest_buffers.appendAssumeCapacity(.{
                .guest_address = guest_address,
                .size = size,
                .upload = upload,
                .device_local = device_local,
            });
            entry_index = self.guest_buffers.items.len - 1;
            self.buffer_cache_misses += 1;
        } else {
            self.buffer_cache_hits += 1;
        }

        const entry = &self.guest_buffers.items[entry_index.?];
        var mapped: ?*anyopaque = null;
        if (self.device_functions.map_memory(self.device, entry.upload.memory, 0, size, 0, &mapped) != vk.success) {
            return Error.MemoryMapFailed;
        }
        const destination: [*]u8 = @ptrCast(mapped orelse {
            self.device_functions.unmap_memory(self.device, entry.upload.memory);
            return Error.MemoryMapFailed;
        });
        const read_ok = memory.read(memory.context, guest_address, destination[0..size]);
        self.device_functions.unmap_memory(self.device, entry.upload.memory);
        if (!read_ok) return Error.GuestMemoryReadFailed;

        const command_buffer = try self.beginOneShot();
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
        const host_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_host_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .buffer = entry.upload.handle,
            .offset = 0,
            .size = entry.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_host_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&host_barrier),
            0,
            null,
        );
        const copy = vk.BufferCopy{ .source_offset = 0, .destination_offset = 0, .size = entry.size };
        self.device_functions.cmd_copy_buffer(command_buffer, entry.upload.handle, entry.device_local.handle, 1, @ptrCast(&copy));
        const shader_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_shader_read_bit | vk.access_shader_write_bit,
            .buffer = entry.device_local.handle,
            .offset = 0,
            .size = entry.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_compute_shader_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&shader_barrier),
            0,
            null,
        );
        try self.submitOneShot(command_buffer);
        self.updateStorageDescriptor(descriptor_index, entry.device_local);
        self.active_descriptor_set = self.descriptor_set;
        self.buffer_uploads += 1;
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
        const readback = try self.createBuffer(
            destination.len,
            vk.buffer_usage_transfer_dst_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(readback);

        const command_buffer = try self.beginOneShot();
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
        const transfer_barrier = vk.BufferMemoryBarrier{
            .source_access_mask = vk.access_shader_write_bit | vk.access_transfer_write_bit,
            .destination_access_mask = vk.access_transfer_read_bit,
            .buffer = entry.device_local.handle,
            .offset = 0,
            .size = entry.size,
        };
        self.device_functions.cmd_pipeline_barrier(
            command_buffer,
            vk.pipeline_stage_compute_shader_bit | vk.pipeline_stage_transfer_bit,
            vk.pipeline_stage_transfer_bit,
            0,
            0,
            null,
            1,
            @ptrCast(&transfer_barrier),
            0,
            null,
        );
        const copy = vk.BufferCopy{ .source_offset = 0, .destination_offset = 0, .size = entry.size };
        self.device_functions.cmd_copy_buffer(command_buffer, entry.device_local.handle, readback.handle, 1, @ptrCast(&copy));
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
        try self.readMapped(readback, destination);
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
        var analysis = try gpu.shader_analysis.decode(self.allocator, reader, program_address, 4096);
        defer analysis.deinit(self.allocator);
        const specialized_scalar_prefix_end = scalarPrefixEnd(&analysis);
        const scalar = gpu.scalar_provenance.evaluatePrefixUntil(reader, &bindings, specialized_scalar_prefix_end);
        var resources = try self.prepareComputeResources(
            &bindings,
            reader,
            &analysis,
            &scalar,
            specialized_scalar_prefix_end,
        );
        var module = try analysis.translateSpirv(self.allocator, .{
            .stage = .compute,
            .local_size = local_size,
            .storage_buffers = resources.mappings[0..resources.mapping_count],
            .scalar_registers = resources.scalar_registers[0..resources.scalar_count],
            .descriptor_array_length = maximum_storage_descriptors,
            .specialized_scalar_prefix_end = resources.specialized_scalar_prefix_end,
        });
        defer module.deinit(self.allocator);
        const report = try self.dispatchSpirv(module.words, group_count);
        try self.commitComputeWrites(memory, &resources);
        return report;
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
                => false,
                .buffer_store_byte,
                .buffer_store_short,
                .buffer_store_dword,
                .buffer_store_dwordx2,
                .buffer_store_dwordx3,
                .buffer_store_dwordx4,
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
            if (inst.src1.kind != .sgpr) return Error.MissingStorageDescriptor;
            const resource_sgpr = inst.src1.reg;
            if (result.mappingForSgpr(resource_sgpr)) |descriptor_index| {
                if (is_store) result.writable[descriptor_index] = true;
                continue;
            }

            const descriptor = (try scalarBufferDescriptor(scalar, resource_sgpr)) orelse {
                return Error.MissingStorageDescriptor;
            };
            if (descriptor.isNull() or descriptor.size_bytes == 0) return Error.MissingStorageDescriptor;
            const size = std.math.cast(usize, descriptor.size_bytes) orelse return Error.GuestBufferTooLarge;
            const descriptor_index = result.descriptorForRange(descriptor.address, size) orelse blk: {
                const free = result.freeDescriptor() orelse return Error.InvalidStorageDescriptor;
                _ = try self.stageGuestStorageBufferAt(free, descriptor.address, size);
                result.occupied[free] = true;
                result.addresses[free] = descriptor.address;
                result.sizes[free] = size;
                break :blk free;
            };
            result.mappings[result.mapping_count] = .{
                .resource_sgpr = resource_sgpr,
                .descriptor_index = descriptor_index,
                .stride = descriptor.stride,
                .swizzled = descriptor.swizzle_enabled,
                .index_stride = descriptor.index_stride,
                .add_thread_id = descriptor.add_thread_id,
            };
            result.mapping_count += 1;
            if (is_store) result.writable[descriptor_index] = true;
        }
        return result;
    }

    fn commitComputeWrites(self: *Renderer, memory: GuestMemory, resources: *const ComputeResources) anyerror!void {
        for (resources.writable, 0..) |writable, index| {
            if (!writable) continue;
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

    fn createGraphicsProbeRenderPass(self: *Renderer) Error!vk.RenderPass {
        const attachment = vk.AttachmentDescription{
            .format = vk.format_r8g8b8a8_unorm,
            .load_operation = vk.attachment_load_op_clear,
            .store_operation = vk.attachment_store_op_store,
            .initial_layout = vk.image_layout_undefined,
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

    fn createGraphicsPipeline(
        self: *Renderer,
        render_pass: vk.RenderPass,
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
            .x = 0,
            .y = 0,
            .width = @floatFromInt(graphics_probe_width),
            .height = @floatFromInt(graphics_probe_height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = graphics_probe_width, .height = graphics_probe_height },
        };
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .viewports = @ptrCast(&viewport),
            .scissor_count = 1,
            .scissors = @ptrCast(&scissor),
        };
        const rasterization = vk.PipelineRasterizationStateCreateInfo{};
        const multisample = vk.PipelineMultisampleStateCreateInfo{};
        const blend_attachment = vk.PipelineColorBlendAttachmentState{};
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
        vertex_words: []const u32,
        fragment_words: []const u32,
    ) (Error || std.mem.Allocator.Error)!vk.Pipeline {
        const vertex_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vertex_words));
        const hash = std.hash.Wyhash.hash(vertex_hash, std.mem.sliceAsBytes(fragment_words));
        for (self.graphics_pipelines.items) |entry| {
            if (entry.hash == hash and
                std.mem.eql(u32, entry.vertex_words, vertex_words) and
                std.mem.eql(u32, entry.fragment_words, fragment_words))
            {
                self.graphics_pipeline_cache_hits += 1;
                return entry.pipeline;
            }
        }
        if (self.graphics_pipelines.items.len >= maximum_graphics_pipelines) {
            return Error.GraphicsPipelineCacheFull;
        }
        const owned_vertex = try self.allocator.dupe(u32, vertex_words);
        errdefer self.allocator.free(owned_vertex);
        const owned_fragment = try self.allocator.dupe(u32, fragment_words);
        errdefer self.allocator.free(owned_fragment);
        const pipeline = try self.createGraphicsPipeline(render_pass, vertex_words, fragment_words);
        errdefer self.device_functions.destroy_pipeline(self.device, pipeline, null);
        try self.graphics_pipelines.append(self.allocator, .{
            .hash = hash,
            .vertex_words = owned_vertex,
            .fragment_words = owned_fragment,
            .pipeline = pipeline,
        });
        self.graphics_pipeline_cache_misses += 1;
        return pipeline;
    }

    fn drawGraphicsShaders(
        self: *Renderer,
        vertex_words: []const u32,
        fragment_words: []const u32,
        validate_diagnostic_color: bool,
    ) (Error || std.mem.Allocator.Error)!void {
        const color = try self.createImage(
            graphics_probe_width,
            graphics_probe_height,
            vk.format_r8g8b8a8_unorm,
            vk.image_usage_color_attachment_bit | vk.image_usage_transfer_src_bit,
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

        const render_pass = try self.createGraphicsProbeRenderPass();
        defer self.device_functions.destroy_render_pass(self.device, render_pass, null);
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = 1,
            .attachments = @ptrCast(&view),
            .width = graphics_probe_width,
            .height = graphics_probe_height,
        };
        var framebuffer: vk.Framebuffer = 0;
        if (self.device_functions.create_framebuffer(self.device, &framebuffer_info, null, &framebuffer) != vk.success) {
            return Error.FramebufferCreationFailed;
        }
        defer self.device_functions.destroy_framebuffer(self.device, framebuffer, null);

        const pipeline = try self.getGraphicsPipeline(render_pass, vertex_words, fragment_words);
        const readback = try self.createBuffer(
            graphics_probe_bytes,
            vk.buffer_usage_transfer_dst_bit,
            vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit,
        );
        defer self.destroyBuffer(readback);

        const command_buffer = try self.beginOneShot();
        defer self.device_functions.free_command_buffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));
        const clear = vk.ClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
        const begin_info = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = graphics_probe_width, .height = graphics_probe_height },
            },
            .clear_value_count = 1,
            .clear_values = @ptrCast(&clear),
        };
        self.device_functions.cmd_begin_render_pass(command_buffer, &begin_info, vk.subpass_contents_inline);
        self.device_functions.cmd_bind_pipeline(command_buffer, vk.pipeline_bind_point_graphics, pipeline);
        self.device_functions.cmd_draw(command_buffer, 3, 1, 0, 0);
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
            .image_extent = .{ .width = graphics_probe_width, .height = graphics_probe_height, .depth = 1 },
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
        try self.readMapped(readback, &self.graphics_probe_frame);

        const center = (@as(usize, graphics_probe_height / 2) * graphics_probe_width + graphics_probe_width / 2) * 4;
        const corner = self.graphics_probe_frame[0..4];
        const center_pixel = self.graphics_probe_frame[center..][0..4];
        if (validate_diagnostic_color and
            (!std.mem.eql(u8, corner, &.{ 0, 0, 0, 255 }) or
                center_pixel[0] < 200 or center_pixel[1] < 40 or center_pixel[1] > 100 or
                center_pixel[2] > 80 or center_pixel[3] != 255))
        {
            return Error.GraphicsProbeReadbackMismatch;
        }
        var colored: u32 = 0;
        var pixel: usize = 0;
        while (pixel < self.graphics_probe_frame.len) : (pixel += 4) {
            if (self.graphics_probe_frame[pixel] != 0 or
                self.graphics_probe_frame[pixel + 1] != 0 or
                self.graphics_probe_frame[pixel + 2] != 0)
            {
                colored += 1;
            }
        }
        if (validate_diagnostic_color and
            (colored == 0 or colored >= graphics_probe_width * graphics_probe_height))
        {
            return Error.GraphicsProbeReadbackMismatch;
        }
        self.graphics_probe_colored_pixels = colored;
    }

    fn drawGraphicsProbe(self: *Renderer) (Error || std.mem.Allocator.Error)!void {
        return self.drawGraphicsShaders(
            &graphics_probe_vertex_spirv,
            &graphics_probe_fragment_spirv,
            true,
        );
    }

    fn drawGuestGraphics(self: *Renderer, state: *const gpu.State) anyerror!void {
        const memory = self.guest_memory orelse return Error.GuestMemoryUnavailable;
        const vertex_address = gpu.resources.ShaderStage.vertex.programAddress(state) orelse {
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
        var vertex_module = try vertex_analysis.translateSpirv(self.allocator, .{
            .stage = .vertex,
            .vertex_index_vgpr = 0,
        });
        defer vertex_module.deinit(self.allocator);
        var fragment_module = try fragment_analysis.translateSpirv(self.allocator, .{ .stage = .fragment });
        defer fragment_module.deinit(self.allocator);
        try self.drawGraphicsShaders(vertex_module.words, fragment_module.words, false);
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
        if (self.device_functions.wait_for_fences(self.device, 1, @ptrCast(&fence), vk.true_value, ~@as(u64, 0)) != vk.success) {
            return Error.FenceWaitFailed;
        }
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
        var index: u32 = 0;
        while (index < self.memory_properties.memory_type_count and index < 32) : (index += 1) {
            const bit = @as(u32, 1) << @intCast(index);
            const flags = self.memory_properties.memory_types[index].property_flags;
            if (supported_bits & bit != 0 and flags & required == required) return index;
        }
        return null;
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
        .draw = dcbDraw,
        .dispatch = dcbDispatch,
    };

    fn fromContext(context: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(context.?));
    }

    fn dcbRead(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const memory = fromContext(context).guest_memory orelse return false;
        return memory.read(memory.context, address, bytes);
    }

    fn dcbWrite(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const memory = fromContext(context).guest_memory orelse return false;
        return memory.write(memory.context, address, bytes);
    }

    fn dcbDraw(context: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
        const self = fromContext(context);
        self.draw_callbacks += 1;
        const has_vertex = gpu.resources.ShaderStage.vertex.programAddress(state) != null;
        const has_fragment = gpu.resources.ShaderStage.pixel.programAddress(state) != null;
        if (!has_vertex and !has_fragment and !self.graphics_probe_enabled) return true;
        if (packet.opcode != gpu.pm4.draw_index_auto or packet.body.len < 1 or packet.body[0] != 3) {
            self.last_draw_error = Error.UnsupportedDrawPacket;
            return false;
        }
        if (has_vertex != has_fragment) {
            self.last_draw_error = Error.MissingGraphicsProgram;
            return false;
        }
        if (has_vertex)
            self.drawGuestGraphics(state) catch |err| {
                self.last_draw_error = err;
                return false;
            }
        else
            self.drawGraphicsProbe() catch |err| {
                self.last_draw_error = err;
                return false;
            };
        if (has_vertex) self.guest_graphics_draws += 1;
        self.translated_draws += 1;
        self.last_draw_error = null;
        return true;
    }

    fn dcbDispatch(context: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
        const self = fromContext(context);
        self.dispatch_callbacks += 1;
        if (packet.opcode != gpu.pm4.dispatch_direct) {
            self.last_dispatch_error = Error.UnsupportedIndirectDispatch;
            return false;
        }
        if (packet.body.len < 3) {
            self.last_dispatch_error = Error.InvalidDispatchPacket;
            return false;
        }
        if (gpu.resources.ShaderStage.compute.programAddress(state) == null) {
            self.last_dispatch_error = Error.MissingComputeProgram;
            return false;
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
            return false;
        };
        self.translated_dispatches += 1;
        self.last_dispatch_error = null;
        return true;
    }
};

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

fn choosePhysicalDevice(
    allocator: std.mem.Allocator,
    instance_handle: vk.Instance,
    functions: *const InstanceFunctions,
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
            if (family.queue_count != 0 and family.queue_flags & vk.required_queue_flags == vk.required_queue_flags) {
                selected_family = @intCast(index);
                break;
            }
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
