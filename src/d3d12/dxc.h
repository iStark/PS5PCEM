// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
#ifndef PS5PCEM_DXC_H
#define PS5PCEM_DXC_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct Ps5Dxc Ps5Dxc;
typedef struct Ps5DxcCode { void *object; const void *bytes; size_t size; } Ps5DxcCode;
int32_t ps5_dxc_create(Ps5Dxc **out, char *error, size_t error_size);
void ps5_dxc_destroy(Ps5Dxc *context);
int32_t ps5_dxc_compile(Ps5Dxc *context, const char *source, const char *profile,
    Ps5DxcCode *out, char *error, size_t error_size);
void ps5_dxc_release(Ps5DxcCode *code);
#ifdef __cplusplus
}
#endif
#endif
