// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Headless Vulkan renderer foundation.
//!
//! This owns the host instance, device, queue and command pool while exposing
//! the existing API-neutral DCB callback boundary. Guest draw/dispatch lowering
//! remains deliberately separate; the smoke path proves that queue submission,
//! a compute pipeline, staging, device-local memory and readback all work.

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
    PipelineLayoutCreationFailed,
    ComputePipelineCreationFailed,
    FenceCreationFailed,
    QueueSubmissionFailed,
    FenceWaitFailed,
    DeviceWaitFailed,
    ReadbackMismatch,
};

pub const Options = struct {
    enable_validation: bool = builtin.mode == .Debug,
};

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

pub const GuestMemory = struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, []u8) bool,
    write: *const fn (?*anyopaque, u64, []const u8) bool,
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
    map_memory: vk.PfnMapMemory,
    unmap_memory: vk.PfnUnmapMemory,
    create_shader_module: vk.PfnCreateShaderModule,
    destroy_shader_module: vk.PfnDestroyShaderModule,
    create_pipeline_layout: vk.PfnCreatePipelineLayout,
    destroy_pipeline_layout: vk.PfnDestroyPipelineLayout,
    create_compute_pipelines: vk.PfnCreateComputePipelines,
    destroy_pipeline: vk.PfnDestroyPipeline,
    cmd_bind_pipeline: vk.PfnCmdBindPipeline,
    cmd_dispatch: vk.PfnCmdDispatch,
    cmd_copy_buffer: vk.PfnCmdCopyBuffer,
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
            .map_memory = try deviceProc(get_proc, device, vk.PfnMapMemory, "vkMapMemory"),
            .unmap_memory = try deviceProc(get_proc, device, vk.PfnUnmapMemory, "vkUnmapMemory"),
            .create_shader_module = try deviceProc(get_proc, device, vk.PfnCreateShaderModule, "vkCreateShaderModule"),
            .destroy_shader_module = try deviceProc(get_proc, device, vk.PfnDestroyShaderModule, "vkDestroyShaderModule"),
            .create_pipeline_layout = try deviceProc(get_proc, device, vk.PfnCreatePipelineLayout, "vkCreatePipelineLayout"),
            .destroy_pipeline_layout = try deviceProc(get_proc, device, vk.PfnDestroyPipelineLayout, "vkDestroyPipelineLayout"),
            .create_compute_pipelines = try deviceProc(get_proc, device, vk.PfnCreateComputePipelines, "vkCreateComputePipelines"),
            .destroy_pipeline = try deviceProc(get_proc, device, vk.PfnDestroyPipeline, "vkDestroyPipeline"),
            .cmd_bind_pipeline = try deviceProc(get_proc, device, vk.PfnCmdBindPipeline, "vkCmdBindPipeline"),
            .cmd_dispatch = try deviceProc(get_proc, device, vk.PfnCmdDispatch, "vkCmdDispatch"),
            .cmd_copy_buffer = try deviceProc(get_proc, device, vk.PfnCmdCopyBuffer, "vkCmdCopyBuffer"),
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
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    loader_api_version: u32,
    device_info: DeviceInfo,
    validation_enabled: bool,
    guest_memory: ?GuestMemory = null,
    draw_callbacks: u64 = 0,
    dispatch_callbacks: u64 = 0,

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
            .memory_properties = memory_properties,
            .loader_api_version = loader_api_version,
            .device_info = candidate.info,
            .validation_enabled = validation_enabled,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.device_functions.device_wait_idle(self.device);
        self.device_functions.destroy_command_pool(self.device, self.command_pool, null);
        self.device_functions.destroy_device(self.device, null);
        self.instance_functions.destroy_instance(self.instance_handle, null);
        self.loader.deinit();
        self.* = undefined;
    }

    /// Attaches the renderer to the existing DCB executor boundary. PM4 remains
    /// API-neutral; callbacks are counted until guest shader/resource lowering
    /// can turn them into real host command recording.
    pub fn dcbBackend(self: *Renderer, memory: GuestMemory) gpu.DcbBackend {
        self.guest_memory = memory;
        return .{ .context = self, .vtable = &dcb_vtable };
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
        const layout_info = vk.PipelineLayoutCreateInfo{};
        var layout: vk.PipelineLayout = 0;
        if (self.device_functions.create_pipeline_layout(self.device, &layout_info, null, &layout) != vk.success) {
            return Error.PipelineLayoutCreationFailed;
        }
        defer self.device_functions.destroy_pipeline_layout(self.device, layout, null);

        const stage = vk.PipelineShaderStageCreateInfo{
            .stage = vk.shader_stage_compute_bit,
            .module = shader,
            .name = "main",
        };
        const pipeline_info = vk.ComputePipelineCreateInfo{ .stage = stage, .layout = layout };
        var pipeline: vk.Pipeline = 0;
        if (self.device_functions.create_compute_pipelines(self.device, 0, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline)) != vk.success) {
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

    fn destroyBuffer(self: *Renderer, buffer: OwnedBuffer) void {
        self.device_functions.destroy_buffer(self.device, buffer.handle, null);
        self.device_functions.free_memory(self.device, buffer.memory, null);
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

    fn createSmokeShader(self: *Renderer) Error!vk.ShaderModule {
        const create_info = vk.ShaderModuleCreateInfo{
            .code_size = smoke_compute_spirv.len * @sizeOf(u32),
            .code = &smoke_compute_spirv,
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

    fn dcbDraw(context: ?*anyopaque, _: *const gpu.State, _: gpu.pm4.Packet) bool {
        fromContext(context).draw_callbacks += 1;
        return true;
    }

    fn dcbDispatch(context: ?*anyopaque, _: *const gpu.State, _: gpu.pm4.Packet) bool {
        fromContext(context).dispatch_callbacks += 1;
        return true;
    }
};

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

test "Vulkan version packing matches the registry layout" {
    const version = vk.makeApiVersion(0, 1, 4, 321);
    try std.testing.expectEqual(@as(u32, 1), vk.apiMajor(version));
    try std.testing.expectEqual(@as(u32, 4), vk.apiMinor(version));
    try std.testing.expectEqual(@as(u32, 321), vk.apiPatch(version));
}
