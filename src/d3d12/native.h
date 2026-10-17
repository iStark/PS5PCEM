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
} Ps5D3D12Info;

typedef struct Ps5D3D12Buffer {
    uint8_t *bytes;
    size_t size;
} Ps5D3D12Buffer;

typedef struct Ps5D3D12Draw {
    uint32_t width, height, vertex_count, instance_count, first_vertex, first_instance;
    uint32_t topology, cull_mode, front_ccw, write_mask;
    float viewport[6];
    int32_t scissor[4];
} Ps5D3D12Draw;

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
int32_t ps5_d3d12_dispatch_spirv(Ps5D3D12 *context, const uint32_t *words, size_t word_count,
    const Ps5D3D12Buffer *buffers, uint32_t buffer_count, const uint32_t groups[3]);
int32_t ps5_d3d12_draw_spirv(Ps5D3D12 *context, const uint32_t *vs, size_t vs_count,
    const uint32_t *ps, size_t ps_count, const Ps5D3D12Draw *draw, uint8_t *rgba);
int32_t ps5_d3d12_present_rgba(Ps5D3D12 *context, const uint8_t *rgba, uint32_t width, uint32_t height);
#endif
