// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
#ifndef PS5PCEM_D3D12_NATIVE_H
#define PS5PCEM_D3D12_NATIVE_H
#include <stdint.h>
#include <stddef.h>

typedef struct Ps5D3D12 Ps5D3D12;
typedef struct Ps5D3D12Info {
    char adapter[128];
    uint64_t dedicated_bytes;
    uint32_t vendor_id;
    uint32_t device_id;
    uint32_t debug_enabled;
    uint32_t shader_model, wave_ops, wave_lane_min, wave_lane_max;
} Ps5D3D12Info;

typedef struct Ps5D3D12CacheStats {
    uint64_t enabled, shader_hits, shader_misses, shader_evictions;
    uint64_t pipeline_hits, pipeline_misses, pipeline_evictions;
    uint64_t shader_entries, pipeline_entries, shader_bytes;
    uint64_t compile_ms, pipeline_ms;
} Ps5D3D12CacheStats;

typedef struct Ps5D3D12ResourceStats {
    uint64_t limit, bytes, entries, hits, misses, evictions, bypasses, create_ms;
} Ps5D3D12ResourceStats;

typedef struct Ps5D3D12UploadStats {
    uint64_t limit, bytes, buffer_hits, image_hits, misses, avoided_bytes, evictions, bypasses;
    /* Uploads skipped by an immutable snapshot ID, independent of `limit`. */
    uint64_t content_hits;
} Ps5D3D12UploadStats;

typedef struct Ps5D3D12AttachmentStats {
    uint64_t enabled, color_hits, depth_hits, misses, avoided_bytes, pairs;
} Ps5D3D12AttachmentStats;

typedef struct Ps5D3D12Buffer {
    uint8_t *bytes;
    size_t size;
} Ps5D3D12Buffer;

typedef struct Ps5D3D12Image {
    const uint8_t *pixels;
    size_t size;
    /* dimension: 0=2D, 1=cube array, 2=2D array. Pixels are layer-major. */
    uint32_t width, height, layers, dimension, mip_levels, format, srgb, components, filter, address_u, address_v, address_w;
    float min_lod, max_lod, lod_bias, border[4];
    /* Nonzero identifies an immutable pixel snapshot. Equal IDs always hold
     * equal pixels, so a completed GPU copy with that ID needs no upload. */
    uint64_t content_id;
} Ps5D3D12Image;

typedef struct Ps5D3D12Blend {
    uint32_t enabled, source_color, destination_color, color_operation;
    uint32_t source_alpha, destination_alpha, alpha_operation;
    float constants[4];
} Ps5D3D12Blend;

typedef struct Ps5D3D12Stencil {
    uint32_t enabled, read_mask, write_mask, reference;
    uint32_t front[4], back[4];
} Ps5D3D12Stencil;

typedef struct Ps5D3D12ColorAttachment {
    uint8_t *pixels; size_t size;
    uint32_t format, write_mask;
    Ps5D3D12Blend blend;
} Ps5D3D12ColorAttachment;

typedef struct Ps5D3D12Draw {
    uint32_t width, height, vertex_count, instance_count, first_vertex, first_instance;
    uint32_t topology, cull_mode, front_ccw, write_mask;
    uint32_t index_count, index_element_bytes, primitive_restart;
    int32_t base_vertex;
    Ps5D3D12Blend blend;
    uint32_t depth_format, depth_write, depth_compare, depth_clip_enabled;
    float depth_bias, depth_bias_clamp, depth_bias_slope;
    uint32_t rectangle_completion, rectangle_mask;
    Ps5D3D12Stencil stencil;
    uint8_t *stencil_pixels; size_t stencil_bytes;
    uint32_t clear_flags; float clear_depth; uint32_t clear_stencil;
    float viewport[6];
    int32_t scissor[4];
    uint32_t dynamic_scalars;
    uint32_t check_dispatcher;
    uint32_t color_attachment;
    uint32_t color_format;
    uint32_t extra_color_count;
    Ps5D3D12ColorAttachment extra_colors[7];
    uint32_t scalar_values[129]; /* VS 0..64, PS 65..128; binding 10. */
} Ps5D3D12Draw;

/* A bounded group shares attachments; all per-draw inputs remain immutable
 * until the single synchronous call returns. */
typedef struct Ps5D3D12DrawJob {
    const uint32_t *vertex; size_t vertex_count;
    const uint32_t *fragment; size_t fragment_count;
    const Ps5D3D12Draw *draw;
    const uint8_t *indices; size_t index_bytes;
    const Ps5D3D12Buffer *buffers; uint32_t buffer_count;
    const Ps5D3D12Image *images; uint32_t image_count;
} Ps5D3D12DrawJob;
int32_t ps5_d3d12_draw_batch(Ps5D3D12 *context, const Ps5D3D12DrawJob *jobs, uint32_t count,
    uint8_t *rgba, uint8_t *depth, size_t depth_bytes);

/* HRESULTs and the operation name are preserved; a failure never falls back
 * to another rendering API or silently accepts an unexecuted command. */
int32_t ps5_d3d12_create(Ps5D3D12 **out, Ps5D3D12Info *info, int debug, char *error, size_t error_size);
void ps5_d3d12_destroy(Ps5D3D12 *context);
const char *ps5_d3d12_error(Ps5D3D12 *context);
int32_t ps5_d3d12_buffer_roundtrip(Ps5D3D12 *context, const uint8_t *source, uint8_t *destination, size_t size);
int32_t ps5_d3d12_compute(Ps5D3D12 *context, uint32_t *destination, uint32_t count, uint32_t multiplier, uint32_t addend);
int32_t ps5_d3d12_render(Ps5D3D12 *context, uint8_t *rgba, uint32_t width, uint32_t height);
int32_t ps5_d3d12_attach_window(Ps5D3D12 *context, void *hwnd, uint32_t width, uint32_t height);
int32_t ps5_d3d12_present(Ps5D3D12 *context, const float rgba[4]);
uint64_t ps5_d3d12_validation_errors(Ps5D3D12 *context);
void ps5_d3d12_cache_stats(Ps5D3D12 *context, Ps5D3D12CacheStats *stats);
void ps5_d3d12_resource_stats(Ps5D3D12 *context, Ps5D3D12ResourceStats *stats);
void ps5_d3d12_upload_stats(Ps5D3D12 *context, Ps5D3D12UploadStats *stats);
void ps5_d3d12_attachment_stats(Ps5D3D12 *context, Ps5D3D12AttachmentStats *stats);
int32_t ps5_d3d12_attachment_cache(Ps5D3D12 *context, int enabled);
/* Exact CPU snapshots prove completed read-only GPU contents; zero disables
 * upload reuse. GPU storage remains subject to the resource-pool budget. */
int32_t ps5_d3d12_upload_cache_limit(Ps5D3D12 *context, uint64_t bytes);
/* Flush completed pooled storage; zero disables pooling. Maximum 4 GiB. */
int32_t ps5_d3d12_resource_pool_limit(Ps5D3D12 *context, uint64_t bytes);
/* Clears cached objects after completion; limits are bounded by the built-in
 * budgets. Zero entries disables caching (also PS5_D3D12_CACHE=0 at creation).
 * Used by the hardware probe to exercise eviction and uncached equivalence. */
int32_t ps5_d3d12_cache_limits(Ps5D3D12 *context, uint32_t shaders, uint32_t pipelines);
int32_t ps5_d3d12_dispatch_spirv(Ps5D3D12 *context, const uint32_t *words, size_t word_count,
    const Ps5D3D12Buffer *buffers, uint32_t buffer_count, const uint32_t groups[3], uint32_t gds);
int32_t ps5_d3d12_draw_spirv(Ps5D3D12 *context, const uint32_t *vs, size_t vs_count,
    const uint32_t *ps, size_t ps_count, const Ps5D3D12Draw *draw, const uint8_t *indices, size_t index_bytes,
    const Ps5D3D12Buffer *buffers, uint32_t buffer_count, const Ps5D3D12Image *images, uint32_t image_count, uint8_t *rgba,
    uint8_t *depth_pixels, size_t depth_bytes);
int32_t ps5_d3d12_present_rgba(Ps5D3D12 *context, const uint8_t *rgba, uint32_t width, uint32_t height);
#endif
