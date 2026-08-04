// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Minimal Vulkan 1.2 ABI used by the renderer bootstrap.
//!
//! Keeping this boundary local avoids making the emulator build depend on a
//! Vulkan SDK. The loader is opened at runtime and every command is resolved
//! through `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`.

const std = @import("std");
const builtin = @import("builtin");

pub const call: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const Result = i32;
pub const Flags = u32;
pub const Bool32 = u32;
pub const DeviceSize = u64;

pub const success: Result = 0;
pub const incomplete: Result = 5;
pub const true_value: Bool32 = 1;
pub const whole_size: DeviceSize = ~@as(DeviceSize, 0);
pub const queue_family_ignored: u32 = ~@as(u32, 0);

pub const api_version_1_2 = makeApiVersion(0, 1, 2, 0);

pub fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

pub fn apiMajor(version: u32) u32 {
    return (version >> 22) & 0x7f;
}

pub fn apiMinor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}

pub fn apiPatch(version: u32) u32 {
    return version & 0xfff;
}

pub const Instance = *opaque {};
pub const PhysicalDevice = *opaque {};
pub const Device = *opaque {};
pub const Queue = *opaque {};
pub const CommandBuffer = *opaque {};

// The emulator is 64-bit. Vulkan non-dispatchable handles are pointer-sized on
// every target we support, so an integer keeps null and ownership explicit.
pub const CommandPool = u64;
pub const Buffer = u64;
pub const DeviceMemory = u64;
pub const Fence = u64;
pub const ShaderModule = u64;
pub const PipelineLayout = u64;
pub const Pipeline = u64;
pub const PipelineCache = u64;

pub const structure_type_application_info: u32 = 0;
pub const structure_type_instance_create_info: u32 = 1;
pub const structure_type_device_queue_create_info: u32 = 2;
pub const structure_type_device_create_info: u32 = 3;
pub const structure_type_submit_info: u32 = 4;
pub const structure_type_memory_allocate_info: u32 = 5;
pub const structure_type_mapped_memory_range: u32 = 6;
pub const structure_type_fence_create_info: u32 = 8;
pub const structure_type_buffer_create_info: u32 = 12;
pub const structure_type_shader_module_create_info: u32 = 16;
pub const structure_type_pipeline_shader_stage_create_info: u32 = 18;
pub const structure_type_compute_pipeline_create_info: u32 = 29;
pub const structure_type_pipeline_layout_create_info: u32 = 30;
pub const structure_type_command_pool_create_info: u32 = 39;
pub const structure_type_command_buffer_allocate_info: u32 = 40;
pub const structure_type_command_buffer_begin_info: u32 = 42;
pub const structure_type_buffer_memory_barrier: u32 = 44;

pub const queue_graphics_bit: Flags = 0x0000_0001;
pub const queue_compute_bit: Flags = 0x0000_0002;
pub const required_queue_flags = queue_graphics_bit | queue_compute_bit;

pub const command_pool_create_transient_bit: Flags = 0x0000_0001;
pub const command_pool_create_reset_command_buffer_bit: Flags = 0x0000_0002;
pub const command_buffer_usage_one_time_submit_bit: Flags = 0x0000_0001;
pub const command_buffer_level_primary: u32 = 0;

pub const buffer_usage_transfer_dst_bit: Flags = 0x0000_0002;
pub const buffer_usage_transfer_src_bit: Flags = 0x0000_0001;
pub const buffer_usage_storage_buffer_bit: Flags = 0x0000_0020;
pub const sharing_mode_exclusive: u32 = 0;

pub const memory_property_host_visible_bit: Flags = 0x0000_0002;
pub const memory_property_host_coherent_bit: Flags = 0x0000_0004;

pub const pipeline_bind_point_compute: u32 = 1;
pub const shader_stage_compute_bit: Flags = 0x0000_0020;
pub const pipeline_stage_transfer_bit: Flags = 0x0000_1000;
pub const pipeline_stage_host_bit: Flags = 0x0000_4000;
pub const access_transfer_read_bit: Flags = 0x0000_0800;
pub const access_transfer_write_bit: Flags = 0x0000_1000;
pub const access_host_read_bit: Flags = 0x0000_2000;
pub const access_host_write_bit: Flags = 0x0000_4000;

pub const physical_device_type_other: u32 = 0;
pub const physical_device_type_integrated_gpu: u32 = 1;
pub const physical_device_type_discrete_gpu: u32 = 2;

pub const ApplicationInfo = extern struct {
    s_type: u32 = structure_type_application_info,
    p_next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8,
    application_version: u32,
    engine_name: ?[*:0]const u8,
    engine_version: u32,
    api_version: u32,
};

pub const InstanceCreateInfo = extern struct {
    s_type: u32 = structure_type_instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    application_info: ?*const ApplicationInfo,
    enabled_layer_count: u32,
    enabled_layer_names: ?[*]const [*:0]const u8,
    enabled_extension_count: u32,
    enabled_extension_names: ?[*]const [*:0]const u8,
};

pub const LayerProperties = extern struct {
    layer_name: [256]u8,
    spec_version: u32,
    implementation_version: u32,
    description: [256]u8,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: Flags,
    queue_count: u32,
    timestamp_valid_bits: u32,
    minimum_image_transfer_granularity: Extent3D,
};

pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: u32 = structure_type_device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_family_index: u32,
    queue_count: u32,
    queue_priorities: [*]const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: u32 = structure_type_device_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_create_info_count: u32,
    queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
    enabled_features: ?*const anyopaque = null,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: u32 = structure_type_command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: u32 = structure_type_command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: u32,
    command_buffer_count: u32,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: u32 = structure_type_command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: Flags,
    inheritance_info: ?*const anyopaque = null,
};

pub const SubmitInfo = extern struct {
    s_type: u32 = structure_type_submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const u64 = null,
    wait_stage_masks: ?[*]const Flags = null,
    command_buffer_count: u32,
    command_buffers: [*]const CommandBuffer,
    signal_semaphore_count: u32 = 0,
    signal_semaphores: ?[*]const u64 = null,
};

pub const FenceCreateInfo = extern struct {
    s_type: u32 = structure_type_fence_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
};

pub const BufferCreateInfo = extern struct {
    s_type: u32 = structure_type_buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    size: DeviceSize,
    usage: Flags,
    sharing_mode: u32 = sharing_mode_exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

pub const MemoryRequirements = extern struct {
    size: DeviceSize,
    alignment: DeviceSize,
    memory_type_bits: u32,
};

pub const MemoryType = extern struct {
    property_flags: Flags,
    heap_index: u32,
};

pub const MemoryHeap = extern struct {
    size: DeviceSize,
    flags: Flags,
};

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: u32 = structure_type_memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: DeviceSize,
    memory_type_index: u32,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: u32 = structure_type_shader_module_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    code_size: usize,
    code: [*]const u32,
};

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    set_layout_count: u32 = 0,
    set_layouts: ?[*]const u64 = null,
    push_constant_range_count: u32 = 0,
    push_constant_ranges: ?*const anyopaque = null,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_shader_stage_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage: Flags,
    module: ShaderModule,
    name: [*:0]const u8,
    specialization_info: ?*const anyopaque = null,
};

pub const ComputePipelineCreateInfo = extern struct {
    s_type: u32 = structure_type_compute_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage: PipelineShaderStageCreateInfo,
    layout: PipelineLayout,
    base_pipeline_handle: Pipeline = 0,
    base_pipeline_index: i32 = -1,
};

pub const BufferMemoryBarrier = extern struct {
    s_type: u32 = structure_type_buffer_memory_barrier,
    p_next: ?*const anyopaque = null,
    source_access_mask: Flags,
    destination_access_mask: Flags,
    source_queue_family_index: u32 = queue_family_ignored,
    destination_queue_family_index: u32 = queue_family_ignored,
    buffer: Buffer,
    offset: DeviceSize,
    size: DeviceSize,
};

pub const BufferCopy = extern struct {
    source_offset: DeviceSize,
    destination_offset: DeviceSize,
    size: DeviceSize,
};

pub const PfnVoidFunction = ?*const anyopaque;
pub const PfnGetInstanceProcAddr = *const fn (?Instance, [*:0]const u8) callconv(call) PfnVoidFunction;
pub const PfnGetDeviceProcAddr = *const fn (Device, [*:0]const u8) callconv(call) PfnVoidFunction;

pub const PfnEnumerateInstanceVersion = *const fn (*u32) callconv(call) Result;
pub const PfnEnumerateInstanceLayerProperties = *const fn (*u32, ?[*]LayerProperties) callconv(call) Result;
pub const PfnCreateInstance = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *?Instance) callconv(call) Result;

pub const PfnDestroyInstance = *const fn (Instance, ?*const anyopaque) callconv(call) void;
pub const PfnEnumeratePhysicalDevices = *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(call) Result;
pub const PfnGetPhysicalDeviceProperties = *const fn (PhysicalDevice, *anyopaque) callconv(call) void;
pub const PfnGetPhysicalDeviceQueueFamilyProperties = *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(call) void;
pub const PfnGetPhysicalDeviceMemoryProperties = *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(call) void;
pub const PfnCreateDevice = *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *?Device) callconv(call) Result;

pub const PfnDestroyDevice = *const fn (Device, ?*const anyopaque) callconv(call) void;
pub const PfnGetDeviceQueue = *const fn (Device, u32, u32, *?Queue) callconv(call) void;
pub const PfnDeviceWaitIdle = *const fn (Device) callconv(call) Result;
pub const PfnCreateCommandPool = *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *CommandPool) callconv(call) Result;
pub const PfnDestroyCommandPool = *const fn (Device, CommandPool, ?*const anyopaque) callconv(call) void;
pub const PfnAllocateCommandBuffers = *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(call) Result;
pub const PfnFreeCommandBuffers = *const fn (Device, CommandPool, u32, [*]const CommandBuffer) callconv(call) void;
pub const PfnBeginCommandBuffer = *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(call) Result;
pub const PfnEndCommandBuffer = *const fn (CommandBuffer) callconv(call) Result;
pub const PfnQueueSubmit = *const fn (Queue, u32, [*]const SubmitInfo, Fence) callconv(call) Result;
pub const PfnCreateFence = *const fn (Device, *const FenceCreateInfo, ?*const anyopaque, *Fence) callconv(call) Result;
pub const PfnDestroyFence = *const fn (Device, Fence, ?*const anyopaque) callconv(call) void;
pub const PfnWaitForFences = *const fn (Device, u32, [*]const Fence, Bool32, u64) callconv(call) Result;
pub const PfnCreateBuffer = *const fn (Device, *const BufferCreateInfo, ?*const anyopaque, *Buffer) callconv(call) Result;
pub const PfnDestroyBuffer = *const fn (Device, Buffer, ?*const anyopaque) callconv(call) void;
pub const PfnGetBufferMemoryRequirements = *const fn (Device, Buffer, *MemoryRequirements) callconv(call) void;
pub const PfnAllocateMemory = *const fn (Device, *const MemoryAllocateInfo, ?*const anyopaque, *DeviceMemory) callconv(call) Result;
pub const PfnFreeMemory = *const fn (Device, DeviceMemory, ?*const anyopaque) callconv(call) void;
pub const PfnBindBufferMemory = *const fn (Device, Buffer, DeviceMemory, DeviceSize) callconv(call) Result;
pub const PfnMapMemory = *const fn (Device, DeviceMemory, DeviceSize, DeviceSize, Flags, *?*anyopaque) callconv(call) Result;
pub const PfnUnmapMemory = *const fn (Device, DeviceMemory) callconv(call) void;
pub const PfnCreateShaderModule = *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *ShaderModule) callconv(call) Result;
pub const PfnDestroyShaderModule = *const fn (Device, ShaderModule, ?*const anyopaque) callconv(call) void;
pub const PfnCreatePipelineLayout = *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *PipelineLayout) callconv(call) Result;
pub const PfnDestroyPipelineLayout = *const fn (Device, PipelineLayout, ?*const anyopaque) callconv(call) void;
pub const PfnCreateComputePipelines = *const fn (Device, PipelineCache, u32, [*]const ComputePipelineCreateInfo, ?*const anyopaque, [*]Pipeline) callconv(call) Result;
pub const PfnDestroyPipeline = *const fn (Device, Pipeline, ?*const anyopaque) callconv(call) void;
pub const PfnCmdBindPipeline = *const fn (CommandBuffer, u32, Pipeline) callconv(call) void;
pub const PfnCmdDispatch = *const fn (CommandBuffer, u32, u32, u32) callconv(call) void;
pub const PfnCmdFillBuffer = *const fn (CommandBuffer, Buffer, DeviceSize, DeviceSize, u32) callconv(call) void;
pub const PfnCmdCopyBuffer = *const fn (CommandBuffer, Buffer, Buffer, u32, [*]const BufferCopy) callconv(call) void;
pub const PfnCmdPipelineBarrier = *const fn (CommandBuffer, Flags, Flags, Flags, u32, ?*const anyopaque, u32, ?[*]const BufferMemoryBarrier, u32, ?*const anyopaque) callconv(call) void;

comptime {
    if (@sizeOf(usize) != 8) @compileError("the Vulkan backend currently requires a 64-bit target");
}
