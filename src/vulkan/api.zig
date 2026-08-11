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
pub const not_ready: Result = 1;
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
pub const DescriptorSetLayout = u64;
pub const DescriptorPool = u64;
pub const DescriptorSet = u64;
pub const Image = u64;
pub const ImageView = u64;
pub const RenderPass = u64;
pub const Framebuffer = u64;
pub const Sampler = u64;
pub const Surface = u64;
pub const Swapchain = u64;

pub const structure_type_application_info: u32 = 0;
pub const structure_type_instance_create_info: u32 = 1;
pub const structure_type_device_queue_create_info: u32 = 2;
pub const structure_type_device_create_info: u32 = 3;
pub const structure_type_submit_info: u32 = 4;
pub const structure_type_memory_allocate_info: u32 = 5;
pub const structure_type_mapped_memory_range: u32 = 6;
pub const structure_type_fence_create_info: u32 = 8;
pub const structure_type_buffer_create_info: u32 = 12;
pub const structure_type_image_create_info: u32 = 14;
pub const structure_type_image_view_create_info: u32 = 15;
pub const structure_type_shader_module_create_info: u32 = 16;
pub const structure_type_pipeline_cache_create_info: u32 = 17;
pub const structure_type_pipeline_shader_stage_create_info: u32 = 18;
pub const structure_type_pipeline_vertex_input_state_create_info: u32 = 19;
pub const structure_type_pipeline_input_assembly_state_create_info: u32 = 20;
pub const structure_type_pipeline_viewport_state_create_info: u32 = 22;
pub const structure_type_pipeline_rasterization_state_create_info: u32 = 23;
pub const structure_type_pipeline_multisample_state_create_info: u32 = 24;
pub const structure_type_pipeline_color_blend_state_create_info: u32 = 26;
pub const structure_type_graphics_pipeline_create_info: u32 = 28;
pub const structure_type_compute_pipeline_create_info: u32 = 29;
pub const structure_type_pipeline_layout_create_info: u32 = 30;
pub const structure_type_sampler_create_info: u32 = 31;
pub const structure_type_descriptor_set_layout_create_info: u32 = 32;
pub const structure_type_descriptor_pool_create_info: u32 = 33;
pub const structure_type_descriptor_set_allocate_info: u32 = 34;
pub const structure_type_write_descriptor_set: u32 = 35;
pub const structure_type_framebuffer_create_info: u32 = 37;
pub const structure_type_render_pass_create_info: u32 = 38;
pub const structure_type_command_pool_create_info: u32 = 39;
pub const structure_type_command_buffer_allocate_info: u32 = 40;
pub const structure_type_command_buffer_begin_info: u32 = 42;
pub const structure_type_render_pass_begin_info: u32 = 43;
pub const structure_type_buffer_memory_barrier: u32 = 44;
pub const structure_type_image_memory_barrier: u32 = 45;
pub const structure_type_swapchain_create_info_khr: u32 = 1_000_001_000;
pub const structure_type_present_info_khr: u32 = 1_000_001_001;
pub const structure_type_win32_surface_create_info_khr: u32 = 1_000_009_000;

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
pub const buffer_usage_index_buffer_bit: Flags = 0x0000_0040;
pub const index_type_uint16: u32 = 0;
pub const index_type_uint32: u32 = 1;
pub const image_usage_transfer_src_bit: Flags = 0x0000_0001;
pub const image_usage_transfer_dst_bit: Flags = 0x0000_0002;
pub const image_usage_color_attachment_bit: Flags = 0x0000_0010;
pub const image_usage_sampled_bit: Flags = 0x0000_0004;
pub const image_usage_storage_bit: Flags = 0x0000_0008;
pub const sharing_mode_exclusive: u32 = 0;

pub const memory_property_host_visible_bit: Flags = 0x0000_0002;
pub const memory_property_host_coherent_bit: Flags = 0x0000_0004;
pub const memory_property_device_local_bit: Flags = 0x0000_0001;

pub const pipeline_bind_point_compute: u32 = 1;
pub const pipeline_bind_point_graphics: u32 = 0;
pub const shader_stage_vertex_bit: Flags = 0x0000_0001;
pub const shader_stage_fragment_bit: Flags = 0x0000_0010;
pub const shader_stage_compute_bit: Flags = 0x0000_0020;
pub const pipeline_stage_transfer_bit: Flags = 0x0000_1000;
pub const pipeline_stage_top_of_pipe_bit: Flags = 0x0000_0001;
pub const pipeline_stage_vertex_shader_bit: Flags = 0x0000_0008;
pub const pipeline_stage_compute_shader_bit: Flags = 0x0000_0800;
pub const pipeline_stage_fragment_shader_bit: Flags = 0x0000_0080;
pub const pipeline_stage_color_attachment_output_bit: Flags = 0x0000_0400;
pub const pipeline_stage_host_bit: Flags = 0x0000_4000;
pub const pipeline_stage_bottom_of_pipe_bit: Flags = 0x0000_2000;
pub const access_shader_read_bit: Flags = 0x0000_0020;
pub const access_shader_write_bit: Flags = 0x0000_0040;
pub const access_transfer_read_bit: Flags = 0x0000_0800;
pub const access_transfer_write_bit: Flags = 0x0000_1000;
pub const access_color_attachment_write_bit: Flags = 0x0000_0100;
pub const access_color_attachment_read_bit: Flags = 0x0000_0080;
pub const access_host_read_bit: Flags = 0x0000_2000;
pub const access_host_write_bit: Flags = 0x0000_4000;

pub const physical_device_type_other: u32 = 0;
pub const physical_device_type_integrated_gpu: u32 = 1;
pub const physical_device_type_discrete_gpu: u32 = 2;

pub const descriptor_type_storage_buffer: u32 = 7;
pub const descriptor_type_combined_image_sampler: u32 = 1;
pub const descriptor_type_storage_image: u32 = 3;

pub const format_r8_unorm: u32 = 9;
pub const format_r8_snorm: u32 = 10;
pub const format_r8_uint: u32 = 13;
pub const format_r8_sint: u32 = 14;
pub const format_r8g8_unorm: u32 = 16;
pub const format_r8g8_snorm: u32 = 17;
pub const format_r8g8_uint: u32 = 20;
pub const format_r8g8_sint: u32 = 21;
pub const format_r16_uint: u32 = 74;
pub const format_r32_uint: u32 = 98;
pub const format_r8g8b8a8_unorm: u32 = 37;
pub const format_r8g8b8a8_uint: u32 = 41;
pub const format_r8g8b8a8_srgb: u32 = 43;
pub const format_r16g16b16a16_sfloat: u32 = 97;
pub const format_r32g32b32a32_sfloat: u32 = 109;
pub const format_b10g11r11_ufloat_pack32: u32 = 122;
pub const format_bc1_rgba_unorm_block: u32 = 133;
pub const format_bc1_rgba_srgb_block: u32 = 134;
pub const format_bc2_unorm_block: u32 = 135;
pub const format_bc2_srgb_block: u32 = 136;
pub const format_bc3_unorm_block: u32 = 137;
pub const format_bc3_srgb_block: u32 = 138;
pub const format_bc4_unorm_block: u32 = 139;
pub const format_bc4_snorm_block: u32 = 140;
pub const format_bc5_unorm_block: u32 = 141;
pub const format_bc5_snorm_block: u32 = 142;
pub const format_bc6h_ufloat_block: u32 = 143;
pub const format_bc6h_sfloat_block: u32 = 144;
pub const format_bc7_unorm_block: u32 = 145;
pub const format_bc7_srgb_block: u32 = 146;
pub const component_swizzle_identity: u32 = 0;
pub const component_swizzle_zero: u32 = 1;
pub const component_swizzle_one: u32 = 2;
pub const component_swizzle_r: u32 = 3;
pub const component_swizzle_g: u32 = 4;
pub const component_swizzle_b: u32 = 5;
pub const component_swizzle_a: u32 = 6;
pub const image_type_2d: u32 = 1;
pub const image_view_type_2d: u32 = 1;
pub const image_tiling_optimal: u32 = 0;
pub const sample_count_1_bit: Flags = 1;
pub const image_layout_undefined: u32 = 0;
pub const image_layout_general: u32 = 1;
pub const image_layout_color_attachment_optimal: u32 = 2;
pub const image_layout_shader_read_only_optimal: u32 = 5;
pub const image_layout_transfer_src_optimal: u32 = 6;
pub const image_layout_transfer_dst_optimal: u32 = 7;
pub const image_layout_present_src_khr: u32 = 1_000_001_002;
pub const image_aspect_color_bit: Flags = 1;
pub const attachment_load_op_clear: u32 = 1;
pub const attachment_load_op_load: u32 = 0;
pub const attachment_store_op_store: u32 = 0;
pub const attachment_load_op_dont_care: u32 = 2;
pub const attachment_store_op_dont_care: u32 = 1;
pub const subpass_external: u32 = ~@as(u32, 0);
pub const primitive_topology_point_list: u32 = 0;
pub const primitive_topology_line_list: u32 = 1;
pub const primitive_topology_line_strip: u32 = 2;
pub const primitive_topology_triangle_list: u32 = 3;
pub const primitive_topology_triangle_strip: u32 = 4;
pub const primitive_topology_triangle_fan: u32 = 5;
pub const polygon_mode_fill: u32 = 0;
pub const color_component_rgba_bits: Flags = 0xf;
pub const subpass_contents_inline: u32 = 0;
pub const filter_nearest: u32 = 0;
pub const format_b8g8r8a8_unorm: u32 = 44;
pub const color_space_srgb_nonlinear_khr: u32 = 0;
pub const present_mode_fifo_khr: u32 = 2;
pub const composite_alpha_opaque_bit_khr: Flags = 0x0000_0001;
pub const surface_transform_identity_bit_khr: Flags = 0x0000_0001;
pub const suboptimal_khr: Result = 1_000_001_003;
pub const error_out_of_date_khr: Result = -1_000_001_004;

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

pub const ImageCreateInfo = extern struct {
    s_type: u32 = structure_type_image_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    image_type: u32 = image_type_2d,
    format: u32,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: Flags = sample_count_1_bit,
    tiling: u32 = image_tiling_optimal,
    usage: Flags,
    sharing_mode: u32 = sharing_mode_exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    initial_layout: u32 = image_layout_undefined,
};

pub const ComponentMapping = extern struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: Flags,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: u32 = structure_type_image_view_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    image: Image,
    view_type: u32 = image_view_type_2d,
    format: u32,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange,
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

pub const PipelineCacheCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_cache_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    initial_data_size: usize = 0,
    initial_data: ?*const anyopaque = null,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: u32,
    descriptor_count: u32,
    stage_flags: Flags,
    immutable_samplers: ?[*]const u64 = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: u32 = structure_type_descriptor_set_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    binding_count: u32,
    bindings: [*]const DescriptorSetLayoutBinding,
};

pub const DescriptorPoolSize = extern struct {
    descriptor_type: u32,
    descriptor_count: u32,
};

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: u32 = structure_type_descriptor_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    max_sets: u32,
    pool_size_count: u32,
    pool_sizes: [*]const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: u32 = structure_type_descriptor_set_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    set_layouts: [*]const DescriptorSetLayout,
};

pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: DeviceSize,
    range: DeviceSize,
};

pub const DescriptorImageInfo = extern struct {
    sampler: Sampler,
    image_view: ImageView,
    image_layout: u32,
};

pub const WriteDescriptorSet = extern struct {
    s_type: u32 = structure_type_write_descriptor_set,
    p_next: ?*const anyopaque = null,
    destination_set: DescriptorSet,
    destination_binding: u32,
    destination_array_element: u32,
    descriptor_count: u32,
    descriptor_type: u32,
    image_info: ?*const anyopaque = null,
    buffer_info: ?[*]const DescriptorBufferInfo = null,
    texel_buffer_view: ?[*]const u64 = null,
};

pub const SamplerCreateInfo = extern struct {
    s_type: u32 = structure_type_sampler_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    magnification_filter: u32,
    minification_filter: u32,
    mipmap_mode: u32,
    address_mode_u: u32,
    address_mode_v: u32,
    address_mode_w: u32,
    mip_lod_bias: f32,
    anisotropy_enable: Bool32 = 0,
    maximum_anisotropy: f32 = 1,
    compare_enable: Bool32 = 0,
    compare_operation: u32 = 7,
    minimum_lod: f32,
    maximum_lod: f32,
    border_color: u32 = 0,
    unnormalized_coordinates: Bool32 = 0,
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

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_vertex_input_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    vertex_binding_description_count: u32 = 0,
    vertex_binding_descriptions: ?*const anyopaque = null,
    vertex_attribute_description_count: u32 = 0,
    vertex_attribute_descriptions: ?*const anyopaque = null,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_input_assembly_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    topology: u32 = primitive_topology_triangle_list,
    primitive_restart_enable: Bool32 = 0,
};

pub const Viewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

pub const Offset2D = extern struct { x: i32, y: i32 };
pub const Extent2D = extern struct { width: u32, height: u32 };
pub const Rect2D = extern struct { offset: Offset2D, extent: Extent2D };

pub const SurfaceCapabilitiesKHR = extern struct {
    minimum_image_count: u32,
    maximum_image_count: u32,
    current_extent: Extent2D,
    minimum_image_extent: Extent2D,
    maximum_image_extent: Extent2D,
    maximum_image_array_layers: u32,
    supported_transforms: Flags,
    current_transform: Flags,
    supported_composite_alpha: Flags,
    supported_usage_flags: Flags,
};

pub const SurfaceFormatKHR = extern struct {
    format: u32,
    color_space: u32,
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: u32 = structure_type_win32_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    instance: *anyopaque,
    window: *anyopaque,
};

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: u32 = structure_type_swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    surface: Surface,
    minimum_image_count: u32,
    image_format: u32,
    image_color_space: u32,
    image_extent: Extent2D,
    image_array_layers: u32 = 1,
    image_usage: Flags,
    image_sharing_mode: u32 = sharing_mode_exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    pre_transform: Flags,
    composite_alpha: Flags,
    present_mode: u32,
    clipped: Bool32 = true_value,
    old_swapchain: Swapchain = 0,
};

pub const PresentInfoKHR = extern struct {
    s_type: u32 = structure_type_present_info_khr,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const u64 = null,
    swapchain_count: u32,
    swapchains: [*]const Swapchain,
    image_indices: [*]const u32,
    results: ?[*]Result = null,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_viewport_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    viewport_count: u32,
    viewports: [*]const Viewport,
    scissor_count: u32,
    scissors: [*]const Rect2D,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_rasterization_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    depth_clamp_enable: Bool32 = 0,
    rasterizer_discard_enable: Bool32 = 0,
    polygon_mode: u32 = polygon_mode_fill,
    cull_mode: Flags = 0,
    front_face: u32 = 0,
    depth_bias_enable: Bool32 = 0,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_multisample_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    rasterization_samples: Flags = sample_count_1_bit,
    sample_shading_enable: Bool32 = 0,
    minimum_sample_shading: f32 = 0,
    sample_mask: ?[*]const u32 = null,
    alpha_to_coverage_enable: Bool32 = 0,
    alpha_to_one_enable: Bool32 = 0,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: Bool32 = 0,
    source_color_blend_factor: u32 = 0,
    destination_color_blend_factor: u32 = 0,
    color_blend_operation: u32 = 0,
    source_alpha_blend_factor: u32 = 0,
    destination_alpha_blend_factor: u32 = 0,
    alpha_blend_operation: u32 = 0,
    color_write_mask: Flags = color_component_rgba_bits,
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: u32 = structure_type_pipeline_color_blend_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    logic_operation_enable: Bool32 = 0,
    logic_operation: u32 = 0,
    attachment_count: u32,
    attachments: [*]const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: u32 = structure_type_graphics_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage_count: u32,
    stages: [*]const PipelineShaderStageCreateInfo,
    vertex_input_state: *const PipelineVertexInputStateCreateInfo,
    input_assembly_state: *const PipelineInputAssemblyStateCreateInfo,
    tessellation_state: ?*const anyopaque = null,
    viewport_state: *const PipelineViewportStateCreateInfo,
    rasterization_state: *const PipelineRasterizationStateCreateInfo,
    multisample_state: *const PipelineMultisampleStateCreateInfo,
    depth_stencil_state: ?*const anyopaque = null,
    color_blend_state: *const PipelineColorBlendStateCreateInfo,
    dynamic_state: ?*const anyopaque = null,
    layout: PipelineLayout,
    render_pass: RenderPass,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = 0,
    base_pipeline_index: i32 = -1,
};

pub const AttachmentDescription = extern struct {
    flags: Flags = 0,
    format: u32,
    samples: Flags = sample_count_1_bit,
    load_operation: u32,
    store_operation: u32,
    stencil_load_operation: u32 = attachment_load_op_dont_care,
    stencil_store_operation: u32 = attachment_store_op_dont_care,
    initial_layout: u32,
    final_layout: u32,
};

pub const AttachmentReference = extern struct { attachment: u32, layout: u32 };

pub const SubpassDescription = extern struct {
    flags: Flags = 0,
    pipeline_bind_point: u32 = pipeline_bind_point_graphics,
    input_attachment_count: u32 = 0,
    input_attachments: ?*const anyopaque = null,
    color_attachment_count: u32,
    color_attachments: [*]const AttachmentReference,
    resolve_attachments: ?*const anyopaque = null,
    depth_stencil_attachment: ?*const anyopaque = null,
    preserve_attachment_count: u32 = 0,
    preserve_attachments: ?[*]const u32 = null,
};

pub const RenderPassCreateInfo = extern struct {
    s_type: u32 = structure_type_render_pass_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    attachment_count: u32,
    attachments: [*]const AttachmentDescription,
    subpass_count: u32,
    subpasses: [*]const SubpassDescription,
    dependency_count: u32 = 0,
    dependencies: ?*const anyopaque = null,
};

pub const FramebufferCreateInfo = extern struct {
    s_type: u32 = structure_type_framebuffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    render_pass: RenderPass,
    attachment_count: u32,
    attachments: [*]const ImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const ClearDepthStencilValue = extern struct { depth: f32, stencil: u32 };
pub const ClearValue = extern union { color: ClearColorValue, depth_stencil: ClearDepthStencilValue };

pub const RenderPassBeginInfo = extern struct {
    s_type: u32 = structure_type_render_pass_begin_info,
    p_next: ?*const anyopaque = null,
    render_pass: RenderPass,
    framebuffer: Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32,
    clear_values: [*]const ClearValue,
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

pub const ImageMemoryBarrier = extern struct {
    s_type: u32 = structure_type_image_memory_barrier,
    p_next: ?*const anyopaque = null,
    source_access_mask: Flags,
    destination_access_mask: Flags,
    old_layout: u32,
    new_layout: u32,
    source_queue_family_index: u32 = queue_family_ignored,
    destination_queue_family_index: u32 = queue_family_ignored,
    image: Image,
    subresource_range: ImageSubresourceRange,
};

pub const BufferCopy = extern struct {
    source_offset: DeviceSize,
    destination_offset: DeviceSize,
    size: DeviceSize,
};

pub const ImageSubresourceLayers = extern struct {
    aspect_mask: Flags,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const Offset3D = extern struct { x: i32, y: i32, z: i32 };

pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers,
    image_offset: Offset3D = .{ .x = 0, .y = 0, .z = 0 },
    image_extent: Extent3D,
};

pub const ImageBlit = extern struct {
    source_subresource: ImageSubresourceLayers,
    source_offsets: [2]Offset3D,
    destination_subresource: ImageSubresourceLayers,
    destination_offsets: [2]Offset3D,
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
pub const PfnCreateWin32SurfaceKHR = *const fn (Instance, *const Win32SurfaceCreateInfoKHR, ?*const anyopaque, *Surface) callconv(call) Result;
pub const PfnDestroySurfaceKHR = *const fn (Instance, Surface, ?*const anyopaque) callconv(call) void;
pub const PfnGetPhysicalDeviceSurfaceSupportKHR = *const fn (PhysicalDevice, u32, Surface, *Bool32) callconv(call) Result;
pub const PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (PhysicalDevice, Surface, *SurfaceCapabilitiesKHR) callconv(call) Result;
pub const PfnGetPhysicalDeviceSurfaceFormatsKHR = *const fn (PhysicalDevice, Surface, *u32, ?[*]SurfaceFormatKHR) callconv(call) Result;

pub const PfnDestroyDevice = *const fn (Device, ?*const anyopaque) callconv(call) void;
pub const PfnGetDeviceQueue = *const fn (Device, u32, u32, *?Queue) callconv(call) void;
pub const PfnDeviceWaitIdle = *const fn (Device) callconv(call) Result;
pub const PfnCreateCommandPool = *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *CommandPool) callconv(call) Result;
pub const PfnDestroyCommandPool = *const fn (Device, CommandPool, ?*const anyopaque) callconv(call) void;
pub const PfnAllocateCommandBuffers = *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(call) Result;
pub const PfnFreeCommandBuffers = *const fn (Device, CommandPool, u32, [*]const CommandBuffer) callconv(call) void;
pub const PfnResetCommandBuffer = *const fn (CommandBuffer, Flags) callconv(call) Result;
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
pub const PfnCreateImage = *const fn (Device, *const ImageCreateInfo, ?*const anyopaque, *Image) callconv(call) Result;
pub const PfnDestroyImage = *const fn (Device, Image, ?*const anyopaque) callconv(call) void;
pub const PfnGetImageMemoryRequirements = *const fn (Device, Image, *MemoryRequirements) callconv(call) void;
pub const PfnBindImageMemory = *const fn (Device, Image, DeviceMemory, DeviceSize) callconv(call) Result;
pub const PfnCreateImageView = *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *ImageView) callconv(call) Result;
pub const PfnDestroyImageView = *const fn (Device, ImageView, ?*const anyopaque) callconv(call) void;
pub const PfnCreateSampler = *const fn (Device, *const SamplerCreateInfo, ?*const anyopaque, *Sampler) callconv(call) Result;
pub const PfnDestroySampler = *const fn (Device, Sampler, ?*const anyopaque) callconv(call) void;
pub const PfnMapMemory = *const fn (Device, DeviceMemory, DeviceSize, DeviceSize, Flags, *?*anyopaque) callconv(call) Result;
pub const PfnUnmapMemory = *const fn (Device, DeviceMemory) callconv(call) void;
pub const PfnCreateShaderModule = *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *ShaderModule) callconv(call) Result;
pub const PfnDestroyShaderModule = *const fn (Device, ShaderModule, ?*const anyopaque) callconv(call) void;
pub const PfnCreatePipelineCache = *const fn (Device, *const PipelineCacheCreateInfo, ?*const anyopaque, *PipelineCache) callconv(call) Result;
pub const PfnDestroyPipelineCache = *const fn (Device, PipelineCache, ?*const anyopaque) callconv(call) void;
pub const PfnGetPipelineCacheData = *const fn (Device, PipelineCache, *usize, ?*anyopaque) callconv(call) Result;
pub const PfnResetFences = *const fn (Device, u32, [*]const Fence) callconv(call) Result;
pub const PfnCreateDescriptorSetLayout = *const fn (Device, *const DescriptorSetLayoutCreateInfo, ?*const anyopaque, *DescriptorSetLayout) callconv(call) Result;
pub const PfnDestroyDescriptorSetLayout = *const fn (Device, DescriptorSetLayout, ?*const anyopaque) callconv(call) void;
pub const PfnCreateDescriptorPool = *const fn (Device, *const DescriptorPoolCreateInfo, ?*const anyopaque, *DescriptorPool) callconv(call) Result;
pub const PfnDestroyDescriptorPool = *const fn (Device, DescriptorPool, ?*const anyopaque) callconv(call) void;
pub const PfnAllocateDescriptorSets = *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(call) Result;
pub const PfnUpdateDescriptorSets = *const fn (Device, u32, [*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(call) void;
pub const PfnCreatePipelineLayout = *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *PipelineLayout) callconv(call) Result;
pub const PfnDestroyPipelineLayout = *const fn (Device, PipelineLayout, ?*const anyopaque) callconv(call) void;
pub const PfnCreateComputePipelines = *const fn (Device, PipelineCache, u32, [*]const ComputePipelineCreateInfo, ?*const anyopaque, [*]Pipeline) callconv(call) Result;
pub const PfnCreateGraphicsPipelines = *const fn (Device, PipelineCache, u32, [*]const GraphicsPipelineCreateInfo, ?*const anyopaque, [*]Pipeline) callconv(call) Result;
pub const PfnCreateRenderPass = *const fn (Device, *const RenderPassCreateInfo, ?*const anyopaque, *RenderPass) callconv(call) Result;
pub const PfnDestroyRenderPass = *const fn (Device, RenderPass, ?*const anyopaque) callconv(call) void;
pub const PfnCreateFramebuffer = *const fn (Device, *const FramebufferCreateInfo, ?*const anyopaque, *Framebuffer) callconv(call) Result;
pub const PfnDestroyFramebuffer = *const fn (Device, Framebuffer, ?*const anyopaque) callconv(call) void;
pub const PfnDestroyPipeline = *const fn (Device, Pipeline, ?*const anyopaque) callconv(call) void;
pub const PfnCmdBindPipeline = *const fn (CommandBuffer, u32, Pipeline) callconv(call) void;
pub const PfnCmdBindDescriptorSets = *const fn (CommandBuffer, u32, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?[*]const u32) callconv(call) void;
pub const PfnCmdDispatch = *const fn (CommandBuffer, u32, u32, u32) callconv(call) void;
pub const PfnCmdBeginRenderPass = *const fn (CommandBuffer, *const RenderPassBeginInfo, u32) callconv(call) void;
pub const PfnCmdEndRenderPass = *const fn (CommandBuffer) callconv(call) void;
pub const PfnCmdDraw = *const fn (CommandBuffer, u32, u32, u32, u32) callconv(call) void;
pub const PfnCmdDrawIndexed = *const fn (CommandBuffer, u32, u32, u32, i32, u32) callconv(call) void;
pub const PfnCmdBindIndexBuffer = *const fn (CommandBuffer, Buffer, DeviceSize, u32) callconv(call) void;
pub const PfnCmdFillBuffer = *const fn (CommandBuffer, Buffer, DeviceSize, DeviceSize, u32) callconv(call) void;
pub const PfnCmdClearColorImage = *const fn (CommandBuffer, Image, u32, *const ClearColorValue, u32, [*]const ImageSubresourceRange) callconv(call) void;
pub const PfnCmdCopyBuffer = *const fn (CommandBuffer, Buffer, Buffer, u32, [*]const BufferCopy) callconv(call) void;
pub const PfnCmdCopyImageToBuffer = *const fn (CommandBuffer, Image, u32, Buffer, u32, [*]const BufferImageCopy) callconv(call) void;
pub const PfnCmdCopyBufferToImage = *const fn (CommandBuffer, Buffer, Image, u32, u32, [*]const BufferImageCopy) callconv(call) void;
pub const PfnCmdBlitImage = *const fn (CommandBuffer, Image, u32, Image, u32, u32, [*]const ImageBlit, u32) callconv(call) void;
pub const PfnCmdPipelineBarrier = *const fn (CommandBuffer, Flags, Flags, Flags, u32, ?*const anyopaque, u32, ?[*]const BufferMemoryBarrier, u32, ?*const anyopaque) callconv(call) void;
pub const PfnCreateSwapchainKHR = *const fn (Device, *const SwapchainCreateInfoKHR, ?*const anyopaque, *Swapchain) callconv(call) Result;
pub const PfnDestroySwapchainKHR = *const fn (Device, Swapchain, ?*const anyopaque) callconv(call) void;
pub const PfnGetSwapchainImagesKHR = *const fn (Device, Swapchain, *u32, ?[*]Image) callconv(call) Result;
pub const PfnAcquireNextImageKHR = *const fn (Device, Swapchain, u64, u64, Fence, *u32) callconv(call) Result;
pub const PfnQueuePresentKHR = *const fn (Queue, *const PresentInfoKHR) callconv(call) Result;

comptime {
    if (@sizeOf(usize) != 8) @compileError("the Vulkan backend currently requires a 64-bit target");
}
