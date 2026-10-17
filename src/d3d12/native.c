// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

/* Thin C ABI for Windows COM interfaces. Rendering policy remains in Zig;
 * this file owns native objects and preserves D3D12 queue/resource ordering. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <dxgi1_6.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <spirv_cross_c.h>
#include "native.h"

typedef HRESULT (WINAPI *CreateFactoryFn)(REFIID, void **);
typedef HRESULT (WINAPI *CreateDeviceFn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
typedef HRESULT (WINAPI *GetDebugFn)(REFIID, void **);
typedef HRESULT (WINAPI *SerializeRootFn)(const D3D12_ROOT_SIGNATURE_DESC *, D3D_ROOT_SIGNATURE_VERSION, ID3DBlob **, ID3DBlob **);
typedef HRESULT (WINAPI *CompileFn)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *, LPCSTR, LPCSTR, UINT, UINT, ID3DBlob **, ID3DBlob **);

enum { BACK_BUFFERS = 3, OFFSCREEN_RTV = 3 };
typedef struct RetiredObject { void *object; struct RetiredObject *next; } RetiredObject;
struct Ps5D3D12 {
    HMODULE dxgi_lib, d3d12_lib, compiler_lib;
    SerializeRootFn serialize;
    CompileFn compile;
    IDXGIFactory4 *factory;
    ID3D12Device *device;
    ID3D12CommandQueue *queue;
    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *commands;
    ID3D12Fence *fence;
    ID3D12InfoQueue *messages;
    HANDLE event;
    uint64_t submitted;
    int pending, poisoned;
    RetiredObject *retired;
    ID3D12DescriptorHeap *rtv_heap, *dsv_heap;
    UINT rtv_stride;
    ID3D12RootSignature *compute_root, *graphics_root;
    ID3D12PipelineState *compute_pipeline, *graphics_pipeline, *present_pipeline;
    IDXGISwapChain3 *swapchain;
    ID3D12Resource *back_buffers[BACK_BUFFERS];
    UINT width, height;
    HWND hwnd;
    char error[1024];
};

static void release(void *object) {
    if (object) IUnknown_Release((IUnknown *)object);
}
static HRESULT failure(Ps5D3D12 *c, HRESULT hr, const char *operation) {
    snprintf(c->error, sizeof(c->error), "%s failed (HRESULT 0x%08lx)", operation, (unsigned long)hr);
    return hr;
}
#define TRY(expr) do { c->error[0] = 0; hr = (expr); if (FAILED(hr)) { if (!c->error[0]) failure(c, hr, #expr); goto done; } } while (0)

static HRESULT wait_idle(Ps5D3D12 *c) {
    if (!c->fence || !c->queue) return S_OK;
    UINT64 completed = ID3D12Fence_GetCompletedValue(c->fence);
    if (completed == UINT64_MAX) return failure(c, DXGI_ERROR_DEVICE_REMOVED, "fence completion");
    if (completed >= c->submitted) { c->pending = 0; return S_OK; }
    HRESULT hr = ID3D12Fence_SetEventOnCompletion(c->fence, c->submitted, c->event);
    if (FAILED(hr)) return failure(c, hr, "SetEventOnCompletion");
    DWORD waited = WaitForSingleObject(c->event, 30000);
    if (waited != WAIT_OBJECT_0) return failure(c, waited == WAIT_TIMEOUT ? HRESULT_FROM_WIN32(ERROR_TIMEOUT) : HRESULT_FROM_WIN32(GetLastError()), "GPU fence wait");
    if (ID3D12Fence_GetCompletedValue(c->fence) == UINT64_MAX) return failure(c, DXGI_ERROR_DEVICE_REMOVED, "fence completion");
    c->pending = 0;
    return S_OK;
}
static void retire(Ps5D3D12 *c, void *object) {
    if (!object) return;
    if (!c->pending || FAILED(ID3D12Device_GetDeviceRemovedReason(c->device))) { release(object); return; }
    RetiredObject *node = malloc(sizeof(*node));
    /* On allocation failure retain the COM reference. Releasing storage still
     * in use by a timed-out GPU is never an acceptable recovery strategy. */
    if (!node) return;
    node->object = object; node->next = c->retired; c->retired = node;
}
static HRESULT begin(Ps5D3D12 *c) {
    if (c->poisoned) return failure(c, E_FAIL, "submission after an incomplete GPU operation");
    HRESULT hr = wait_idle(c);
    if (FAILED(hr)) return hr;
    hr = ID3D12CommandAllocator_Reset(c->allocator);
    if (FAILED(hr)) return failure(c, hr, "Reset command allocator");
    hr = ID3D12GraphicsCommandList_Reset(c->commands, c->allocator, NULL);
    return FAILED(hr) ? failure(c, hr, "Reset command list") : hr;
}
static HRESULT submit(Ps5D3D12 *c) {
    HRESULT hr = ID3D12GraphicsCommandList_Close(c->commands);
    if (FAILED(hr)) return failure(c, hr, "Close command list");
    ID3D12CommandList *lists[] = { (ID3D12CommandList *)c->commands };
    c->pending = 1;
    ID3D12CommandQueue_ExecuteCommandLists(c->queue, 1, lists);
    const UINT64 next = c->submitted + 1;
    c->submitted = next;
    hr = ID3D12CommandQueue_Signal(c->queue, c->fence, next);
    if (FAILED(hr)) { c->poisoned = 1; return failure(c, hr, "Signal fence"); }
    hr = wait_idle(c);
    if (FAILED(hr)) c->poisoned = 1;
    return hr;
}
static void transition(Ps5D3D12 *c, ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    if (before == after) return;
    D3D12_RESOURCE_BARRIER barrier = {0};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    ID3D12GraphicsCommandList_ResourceBarrier(c->commands, 1, &barrier);
}
static D3D12_CPU_DESCRIPTOR_HANDLE rtv(Ps5D3D12 *c, UINT index) {
    D3D12_CPU_DESCRIPTOR_HANDLE h = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(c->rtv_heap);
    h.ptr += (SIZE_T)index * c->rtv_stride;
    return h;
}
static HRESULT buffer(Ps5D3D12 *c, UINT64 size, D3D12_HEAP_TYPE type, D3D12_RESOURCE_STATES state, D3D12_RESOURCE_FLAGS flags, ID3D12Resource **out) {
    D3D12_HEAP_PROPERTIES heap = {0};
    heap.Type = type;
    D3D12_RESOURCE_DESC desc = {0};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = size;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags = flags;
    return ID3D12Device_CreateCommittedResource(c->device, &heap, D3D12_HEAP_FLAG_NONE, &desc, state, NULL, &IID_ID3D12Resource, (void **)out);
}

int32_t ps5_d3d12_create(Ps5D3D12 **out, Ps5D3D12Info *info, int debug, char *error, size_t error_size) {
    if (!out || !info || !error || !error_size) return E_INVALIDARG;
    *out = NULL;
    memset(info, 0, sizeof(*info));
    error[0] = 0;
    Ps5D3D12 *c = calloc(1, sizeof(*c));
    if (!c) return E_OUTOFMEMORY;
    HRESULT hr = S_OK;
    IDXGIAdapter1 *selected = NULL;
    ID3D12Debug *debugger = NULL;
    SIZE_T largest = 0;
    DXGI_ADAPTER_DESC1 selected_desc = {0};
    c->dxgi_lib = LoadLibraryExW(L"dxgi.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    c->d3d12_lib = LoadLibraryExW(L"d3d12.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!c->dxgi_lib || !c->d3d12_lib) { hr = failure(c, HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND), "DirectX 12 system libraries"); goto done; }
    CreateFactoryFn factory_fn = (CreateFactoryFn)GetProcAddress(c->dxgi_lib, "CreateDXGIFactory1");
    CreateDeviceFn device_fn = (CreateDeviceFn)GetProcAddress(c->d3d12_lib, "D3D12CreateDevice");
    c->serialize = (SerializeRootFn)GetProcAddress(c->d3d12_lib, "D3D12SerializeRootSignature");
    if (!factory_fn || !device_fn || !c->serialize) { hr = failure(c, E_NOINTERFACE, "DirectX 12 entry points"); goto done; }
    if (debug) {
        GetDebugFn get_debug = (GetDebugFn)GetProcAddress(c->d3d12_lib, "D3D12GetDebugInterface");
        if (!get_debug) { hr = failure(c, E_NOINTERFACE, "D3D12 debug interface"); goto done; }
        TRY(get_debug(&IID_ID3D12Debug, (void **)&debugger));
        ID3D12Debug_EnableDebugLayer(debugger);
        info->debug_enabled = 1;
    }
    TRY(factory_fn(&IID_IDXGIFactory4, (void **)&c->factory));
    for (UINT index = 0;; ++index) {
        IDXGIAdapter1 *adapter = NULL;
        hr = IDXGIFactory4_EnumAdapters1(c->factory, index, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) { hr = S_OK; break; }
        if (FAILED(hr)) { failure(c, hr, "EnumAdapters1"); goto done; }
        DXGI_ADAPTER_DESC1 desc = {0};
        HRESULT result = IDXGIAdapter1_GetDesc1(adapter, &desc);
        if (SUCCEEDED(result) && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
            SUCCEEDED(device_fn((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, NULL)) &&
            (!selected || desc.DedicatedVideoMemory > largest)) {
            release(selected);
            selected = adapter;
            selected_desc = desc;
            largest = desc.DedicatedVideoMemory;
        } else release(adapter);
    }
    if (!selected) { hr = failure(c, DXGI_ERROR_UNSUPPORTED, "hardware D3D12 adapter selection"); goto done; }
    TRY(device_fn((IUnknown *)selected, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&c->device));
    WideCharToMultiByte(CP_UTF8, 0, selected_desc.Description, -1, info->adapter, sizeof(info->adapter), NULL, NULL);
    info->dedicated_bytes = largest;
    info->vendor_id = selected_desc.VendorId;
    info->device_id = selected_desc.DeviceId;
    if (debug) TRY(ID3D12Device_QueryInterface(c->device, &IID_ID3D12InfoQueue, (void **)&c->messages));
    D3D12_COMMAND_QUEUE_DESC queue = {0};
    queue.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    TRY(ID3D12Device_CreateCommandQueue(c->device, &queue, &IID_ID3D12CommandQueue, (void **)&c->queue));
    TRY(ID3D12Device_CreateCommandAllocator(c->device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&c->allocator));
    TRY(ID3D12Device_CreateCommandList(c->device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, c->allocator, NULL, &IID_ID3D12GraphicsCommandList, (void **)&c->commands));
    TRY(ID3D12GraphicsCommandList_Close(c->commands));
    TRY(ID3D12Device_CreateFence(c->device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&c->fence));
    c->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!c->event) { hr = failure(c, HRESULT_FROM_WIN32(GetLastError()), "CreateEventW"); goto done; }
    D3D12_DESCRIPTOR_HEAP_DESC heap = {0};
    heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap.NumDescriptors = BACK_BUFFERS + 1;
    TRY(ID3D12Device_CreateDescriptorHeap(c->device, &heap, &IID_ID3D12DescriptorHeap, (void **)&c->rtv_heap));
    c->rtv_stride = ID3D12Device_GetDescriptorHandleIncrementSize(c->device, heap.Type);
    heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
    heap.NumDescriptors = 1;
    TRY(ID3D12Device_CreateDescriptorHeap(c->device, &heap, &IID_ID3D12DescriptorHeap, (void **)&c->dsv_heap));
done:
    release(debugger);
    release(selected);
    if (FAILED(hr)) {
        snprintf(error, error_size, "%s", c->error);
        ps5_d3d12_destroy(c);
    } else *out = c;
    return hr;
}

void ps5_d3d12_destroy(Ps5D3D12 *c) {
    if (!c) return;
    wait_idle(c);
    if (c->pending && c->device && SUCCEEDED(ID3D12Device_GetDeviceRemovedReason(c->device))) {
        fprintf(stderr, "[d3d12] GPU did not finish; retaining in-flight objects until process exit\n");
        return;
    }
    while (c->retired) {
        RetiredObject *node = c->retired;
        c->retired = node->next;
        release(node->object); free(node);
    }
    for (UINT i = 0; i < BACK_BUFFERS; ++i) release(c->back_buffers[i]);
    release(c->swapchain);
    release(c->present_pipeline);
    release(c->graphics_pipeline);
    release(c->compute_pipeline);
    release(c->graphics_root);
    release(c->compute_root);
    release(c->rtv_heap);
    release(c->dsv_heap);
    release(c->commands);
    release(c->allocator);
    release(c->fence);
    release(c->queue);
    release(c->messages);
    release(c->device);
    release(c->factory);
    if (c->event) CloseHandle(c->event);
    if (c->compiler_lib) FreeLibrary(c->compiler_lib);
    if (c->d3d12_lib) FreeLibrary(c->d3d12_lib);
    if (c->dxgi_lib) FreeLibrary(c->dxgi_lib);
    free(c);
}
const char *ps5_d3d12_error(Ps5D3D12 *c) { return c->error; }

int32_t ps5_d3d12_buffer_roundtrip(Ps5D3D12 *c, const uint8_t *source, uint8_t *destination, size_t size) {
    if (!c || !source || !destination || !size) return E_INVALIDARG;
    HRESULT hr;
    ID3D12Resource *upload = NULL, *gpu = NULL, *readback = NULL;
    void *mapped = NULL;
    D3D12_RANGE empty = {0, 0}, entire = {0, size};
    TRY(buffer(c, size, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, 0, &upload));
    TRY(buffer(c, size, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST, 0, &gpu));
    TRY(buffer(c, size, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST, 0, &readback));
    TRY(ID3D12Resource_Map(upload, 0, &empty, &mapped));
    memcpy(mapped, source, size);
    ID3D12Resource_Unmap(upload, 0, &entire);
    TRY(begin(c));
    ID3D12GraphicsCommandList_CopyBufferRegion(c->commands, gpu, 0, upload, 0, size);
    transition(c, gpu, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
    ID3D12GraphicsCommandList_CopyBufferRegion(c->commands, readback, 0, gpu, 0, size);
    TRY(submit(c));
    TRY(ID3D12Resource_Map(readback, 0, &entire, &mapped));
    memcpy(destination, mapped, size);
    ID3D12Resource_Unmap(readback, 0, &empty);
done:
    retire(c, readback); retire(c, gpu); retire(c, upload);
    return hr;
}

static HRESULT compile(Ps5D3D12 *c, const char *source, const char *entry, const char *profile, ID3DBlob **blob) {
    if (!c->compiler_lib) {
        c->compiler_lib = LoadLibraryExW(L"d3dcompiler_47.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!c->compiler_lib) return failure(c, HRESULT_FROM_WIN32(GetLastError()), "D3DCompiler_47");
        c->compile = (CompileFn)GetProcAddress(c->compiler_lib, "D3DCompile");
    }
    if (!c->compile) return failure(c, E_NOINTERFACE, "D3DCompile");
    ID3DBlob *errors = NULL;
    HRESULT hr = c->compile(source, strlen(source), "PS5PCEM native D3D12", NULL, NULL, entry, profile, D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, blob, &errors);
    if (FAILED(hr)) snprintf(c->error, sizeof(c->error), "HLSL %s/%s: %.*s", entry, profile, errors ? (int)ID3D10Blob_GetBufferSize(errors) : 0, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "");
    release(errors);
    return hr;
}
static HRESULT root_signature(Ps5D3D12 *c, int compute, ID3D12RootSignature **out) {
    D3D12_ROOT_PARAMETER params[2] = {0};
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    params[0].Constants.Num32BitValues = 8;
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_ROOT_SIGNATURE_DESC desc = {0};
    desc.NumParameters = compute ? 2 : 1;
    desc.pParameters = params;
    desc.Flags = compute ? 0 : D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = c->serialize(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
    if (SUCCEEDED(hr)) hr = ID3D12Device_CreateRootSignature(c->device, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)out);
    release(blob); release(errors);
    return hr;
}

/* SPIR-V is the shared shader IR, not a host graphics API here. SPIRV-Cross
 * emits HLSL, which the Windows compiler turns into native D3D bytecode.
 * Reflection rejects resources not yet bound by this backend. */
static HRESULT compile_spirv(Ps5D3D12 *c, const uint32_t *words, size_t word_count,
    SpvExecutionModel stage, uint32_t buffer_count, ID3DBlob **code) {
    spvc_context context = NULL;
    spvc_parsed_ir ir = NULL;
    spvc_compiler compiler = NULL;
    spvc_compiler_options options = NULL;
    spvc_resources resources = NULL;
    spvc_set active = NULL;
    HRESULT hr = E_FAIL;
    const char *source = NULL;
    if (spvc_context_create(&context) != SPVC_SUCCESS) return E_OUTOFMEMORY;
#define CROSS(expr) do { if ((expr) != SPVC_SUCCESS) { snprintf(c->error, sizeof(c->error), "SPIRV-Cross %s: %s", #expr, spvc_context_get_last_error_string(context)); goto done; } } while (0)
    CROSS(spvc_context_parse_spirv(context, words, word_count, &ir));
    CROSS(spvc_context_create_compiler(context, SPVC_BACKEND_HLSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler));
    CROSS(spvc_compiler_set_entry_point(compiler, "main", stage));
    CROSS(spvc_compiler_create_compiler_options(compiler, &options));
    CROSS(spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL, 51));
    CROSS(spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_HLSL_FORCE_STORAGE_BUFFER_AS_UAV, SPVC_TRUE));
    if (stage == SpvExecutionModelVertex)
        CROSS(spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_HLSL_SUPPORT_NONZERO_BASE_VERTEX_BASE_INSTANCE, SPVC_TRUE));
    CROSS(spvc_compiler_install_compiler_options(compiler, options));
    CROSS(spvc_compiler_get_active_interface_variables(compiler, &active));
    CROSS(spvc_compiler_set_enabled_interface_variables(compiler, active));
    CROSS(spvc_compiler_create_shader_resources_for_active_variables(compiler, &resources, active));
    for (spvc_resource_type kind = SPVC_RESOURCE_TYPE_UNIFORM_BUFFER; kind <= SPVC_RESOURCE_TYPE_SHADER_RECORD_BUFFER; ++kind) {
        if (kind == SPVC_RESOURCE_TYPE_STAGE_INPUT || kind == SPVC_RESOURCE_TYPE_STAGE_OUTPUT || kind == SPVC_RESOURCE_TYPE_RAY_QUERY) continue;
        const spvc_reflected_resource *list = NULL;
        size_t count = 0;
        CROSS(spvc_resources_get_resource_list_for_type(resources, kind, &list, &count));
        if (!count) continue;
        if (kind != SPVC_RESOURCE_TYPE_STORAGE_BUFFER || count != 1 || !buffer_count) {
            snprintf(c->error, sizeof(c->error), "D3D12 shader resource kind %u/count %zu is not supported by this pipeline", kind, count);
            goto done;
        }
        const unsigned set = spvc_compiler_get_decoration(compiler, list[0].id, SpvDecorationDescriptorSet);
        const unsigned binding = spvc_compiler_get_decoration(compiler, list[0].id, SpvDecorationBinding);
        spvc_type type = spvc_compiler_get_type_handle(compiler, list[0].type_id);
        if (set != 0 || binding != 0 || spvc_type_get_num_array_dimensions(type) != 1 ||
            !spvc_type_array_dimension_is_literal(type, 0) || spvc_type_get_array_dimension(type, 0) != buffer_count) {
            snprintf(c->error, sizeof(c->error), "D3D12 storage descriptors require set 0/binding 0 and exactly %u buffers", buffer_count);
            goto done;
        }
    }
    CROSS(spvc_compiler_compile(compiler, &source));
    hr = compile(c, source, "main", stage == SpvExecutionModelGLCompute ? "cs_5_1" : stage == SpvExecutionModelVertex ? "vs_5_1" : "ps_5_1", code);
done:
    spvc_context_destroy(context);
    return hr;
#undef CROSS
}

static HRESULT storage_root(Ps5D3D12 *c, uint32_t count, ID3D12RootSignature **root) {
    D3D12_DESCRIPTOR_RANGE range = {0};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
    range.NumDescriptors = count;
    D3D12_ROOT_PARAMETER parameter = {0};
    parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameter.DescriptorTable.NumDescriptorRanges = 1;
    parameter.DescriptorTable.pDescriptorRanges = &range;
    D3D12_ROOT_SIGNATURE_DESC desc = {0};
    desc.NumParameters = count ? 1 : 0;
    desc.pParameters = &parameter;
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = c->serialize(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
    if (SUCCEEDED(hr)) hr = ID3D12Device_CreateRootSignature(c->device, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)root);
    release(blob); release(errors);
    return hr;
}

static HRESULT guest_graphics_root(Ps5D3D12 *c, ID3D12RootSignature **root) {
    // Guest graphics resources are still rejected. SPIRV-Cross's auxiliary
    // VertexInfo is therefore the sole cbuffer, assigned b0 by D3DCompiler.
    // D3D's SV_VertexID/InstanceID exclude the draw's base values; Vulkan's
    // VertexIndex/InstanceIndex (used by the shared translator) include them.
    D3D12_ROOT_PARAMETER parameter = {0};
    parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    parameter.Constants.Num32BitValues = 2;
    parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
    D3D12_ROOT_SIGNATURE_DESC desc = {0};
    desc.NumParameters = 1;
    desc.pParameters = &parameter;
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = c->serialize(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
    if (SUCCEEDED(hr)) hr = ID3D12Device_CreateRootSignature(c->device, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)root);
    release(blob); release(errors);
    return hr;
}

int32_t ps5_d3d12_dispatch_spirv(Ps5D3D12 *c, const uint32_t *words, size_t word_count,
    const Ps5D3D12Buffer *buffers, uint32_t count, const uint32_t groups[3]) {
    if (!c || !words || word_count < 5 || count > 64 || (count && !buffers) || !groups) return E_INVALIDARG;
    for (UINT axis = 0; axis < 3; ++axis) if (!groups[axis] || groups[axis] > 65535) return E_INVALIDARG;
    for (UINT i = 0; i < count; ++i) if (!buffers[i].bytes || !buffers[i].size || buffers[i].size % 4 || buffers[i].size > 256 * 1024 * 1024) return E_INVALIDARG;
    HRESULT hr;
    ID3DBlob *code = NULL;
    ID3D12RootSignature *root = NULL;
    ID3D12PipelineState *pipeline = NULL;
    ID3D12DescriptorHeap *heap = NULL;
    ID3D12Resource *gpu[64] = {0}, *upload[64] = {0}, *readback[64] = {0};
    TRY(compile_spirv(c, words, word_count, SpvExecutionModelGLCompute, count, &code));
    TRY(storage_root(c, count, &root));
    D3D12_COMPUTE_PIPELINE_STATE_DESC desc = {0};
    desc.pRootSignature = root;
    desc.CS.pShaderBytecode = ID3D10Blob_GetBufferPointer(code);
    desc.CS.BytecodeLength = ID3D10Blob_GetBufferSize(code);
    TRY(ID3D12Device_CreateComputePipelineState(c->device, &desc, &IID_ID3D12PipelineState, (void **)&pipeline));
    if (count) {
        D3D12_DESCRIPTOR_HEAP_DESC descriptors = {0};
        descriptors.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        descriptors.NumDescriptors = count;
        descriptors.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        TRY(ID3D12Device_CreateDescriptorHeap(c->device, &descriptors, &IID_ID3D12DescriptorHeap, (void **)&heap));
        D3D12_CPU_DESCRIPTOR_HANDLE handle = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
        UINT stride = ID3D12Device_GetDescriptorHandleIncrementSize(c->device, descriptors.Type);
        for (UINT i = 0; i < count; ++i) {
            TRY(buffer(c, buffers[i].size, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, &gpu[i]));
            TRY(buffer(c, buffers[i].size, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, 0, &upload[i]));
            TRY(buffer(c, buffers[i].size, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST, 0, &readback[i]));
            void *mapped;
            D3D12_RANGE empty = {0, 0}, entire = {0, buffers[i].size};
            TRY(ID3D12Resource_Map(upload[i], 0, &empty, &mapped));
            memcpy(mapped, buffers[i].bytes, buffers[i].size);
            ID3D12Resource_Unmap(upload[i], 0, &entire);
            D3D12_UNORDERED_ACCESS_VIEW_DESC view = {0};
            view.Format = DXGI_FORMAT_R32_TYPELESS;
            view.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
            view.Buffer.NumElements = (UINT)(buffers[i].size / 4);
            view.Buffer.Flags = D3D12_BUFFER_UAV_FLAG_RAW;
            ID3D12Device_CreateUnorderedAccessView(c->device, gpu[i], NULL, &view, handle);
            handle.ptr += stride;
        }
    }
    TRY(begin(c));
    for (UINT i = 0; i < count; ++i) {
        ID3D12GraphicsCommandList_CopyBufferRegion(c->commands, gpu[i], 0, upload[i], 0, buffers[i].size);
        transition(c, gpu[i], D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    }
    ID3D12GraphicsCommandList_SetPipelineState(c->commands, pipeline);
    ID3D12GraphicsCommandList_SetComputeRootSignature(c->commands, root);
    if (count) {
        ID3D12GraphicsCommandList_SetDescriptorHeaps(c->commands, 1, &heap);
        ID3D12GraphicsCommandList_SetComputeRootDescriptorTable(c->commands, 0, ID3D12DescriptorHeap_GetGPUDescriptorHandleForHeapStart(heap));
    }
    ID3D12GraphicsCommandList_Dispatch(c->commands, groups[0], groups[1], groups[2]);
    for (UINT i = 0; i < count; ++i) {
        transition(c, gpu[i], D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
        ID3D12GraphicsCommandList_CopyBufferRegion(c->commands, readback[i], 0, gpu[i], 0, buffers[i].size);
    }
    TRY(submit(c));
    for (UINT i = 0; i < count; ++i) {
        void *mapped;
        D3D12_RANGE entire = {0, buffers[i].size}, empty = {0, 0};
        TRY(ID3D12Resource_Map(readback[i], 0, &entire, &mapped));
        memcpy(buffers[i].bytes, mapped, buffers[i].size);
        ID3D12Resource_Unmap(readback[i], 0, &empty);
    }
done:
    for (UINT i = 0; i < count; ++i) { retire(c, readback[i]); retire(c, upload[i]); retire(c, gpu[i]); }
    retire(c, heap); retire(c, pipeline); retire(c, root); release(code);
    return hr;
}

int32_t ps5_d3d12_compute(Ps5D3D12 *c, uint32_t *destination, uint32_t count, uint32_t multiplier, uint32_t addend) {
    if (!c || !destination || !count || count > 65535u * 64u) return E_INVALIDARG;
    HRESULT hr;
    ID3D12Resource *gpu = NULL, *readback = NULL;
    ID3DBlob *code = NULL;
    const size_t bytes = (size_t)count * 4;
    if (!c->compute_root) TRY(root_signature(c, 1, &c->compute_root));
    if (!c->compute_pipeline) {
        TRY(compile(c, "cbuffer C:register(b0){uint n;uint mul;uint add;} RWStructuredBuffer<uint> output:register(u0); [numthreads(64,1,1)] void main(uint3 id:SV_DispatchThreadID){if(id.x<n)output[id.x]=id.x*mul+add;}", "main", "cs_5_1", &code));
        D3D12_COMPUTE_PIPELINE_STATE_DESC desc = {0};
        desc.pRootSignature = c->compute_root;
        desc.CS.pShaderBytecode = ID3D10Blob_GetBufferPointer(code);
        desc.CS.BytecodeLength = ID3D10Blob_GetBufferSize(code);
        TRY(ID3D12Device_CreateComputePipelineState(c->device, &desc, &IID_ID3D12PipelineState, (void **)&c->compute_pipeline));
    }
    TRY(buffer(c, bytes, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, &gpu));
    TRY(buffer(c, bytes, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST, 0, &readback));
    TRY(begin(c));
    uint32_t constants[] = {count, multiplier, addend};
    ID3D12GraphicsCommandList_SetPipelineState(c->commands, c->compute_pipeline);
    ID3D12GraphicsCommandList_SetComputeRootSignature(c->commands, c->compute_root);
    ID3D12GraphicsCommandList_SetComputeRoot32BitConstants(c->commands, 0, 3, constants, 0);
    ID3D12GraphicsCommandList_SetComputeRootUnorderedAccessView(c->commands, 1, ID3D12Resource_GetGPUVirtualAddress(gpu));
    ID3D12GraphicsCommandList_Dispatch(c->commands, (count + 63) / 64, 1, 1);
    transition(c, gpu, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    ID3D12GraphicsCommandList_CopyBufferRegion(c->commands, readback, 0, gpu, 0, bytes);
    TRY(submit(c));
    void *mapped = NULL;
    D3D12_RANGE range = {0, bytes}, empty = {0, 0};
    TRY(ID3D12Resource_Map(readback, 0, &range, &mapped));
    memcpy(destination, mapped, bytes);
    ID3D12Resource_Unmap(readback, 0, &empty);
done:
    release(code); retire(c, readback); retire(c, gpu);
    return hr;
}

static D3D12_GRAPHICS_PIPELINE_STATE_DESC graphics_desc(ID3D12RootSignature *root, ID3DBlob *vs, ID3DBlob *ps, int depth) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = {0};
    desc.pRootSignature = root;
    desc.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
    desc.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
    desc.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(ps);
    desc.PS.BytecodeLength = ID3D10Blob_GetBufferSize(ps);
    desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    desc.RasterizerState.DepthClipEnable = TRUE;
    desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    desc.BlendState.RenderTarget[0].SrcBlend = D3D12_BLEND_ONE;
    desc.BlendState.RenderTarget[0].DestBlend = D3D12_BLEND_ZERO;
    desc.BlendState.RenderTarget[0].BlendOp = D3D12_BLEND_OP_ADD;
    desc.BlendState.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND_ONE;
    desc.BlendState.RenderTarget[0].DestBlendAlpha = D3D12_BLEND_ZERO;
    desc.BlendState.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP_ADD;
    desc.BlendState.RenderTarget[0].LogicOp = D3D12_LOGIC_OP_NOOP;
    desc.DepthStencilState.DepthEnable = depth;
    desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    desc.DepthStencilState.FrontFace.StencilFailOp = D3D12_STENCIL_OP_KEEP;
    desc.DepthStencilState.FrontFace.StencilDepthFailOp = D3D12_STENCIL_OP_KEEP;
    desc.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_KEEP;
    desc.DepthStencilState.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    desc.DepthStencilState.BackFace = desc.DepthStencilState.FrontFace;
    desc.SampleMask = UINT_MAX;
    desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    desc.NumRenderTargets = 1;
    desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.DSVFormat = depth ? DXGI_FORMAT_D32_FLOAT : DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    return desc;
}

static HRESULT graphics_pipeline(Ps5D3D12 *c, int depth) {
    HRESULT hr;
    ID3DBlob *vs = NULL, *ps = NULL;
    ID3D12PipelineState **pipeline = depth ? &c->graphics_pipeline : &c->present_pipeline;
    if (*pipeline) return S_OK;
    if (!c->graphics_root) TRY(root_signature(c, 0, &c->graphics_root));
    const char *source = "cbuffer C:register(b0){float4 tint;float z;} float4 VS(uint id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),z,1);} float4 PS():SV_Target{return tint;}";
    TRY(compile(c, source, "VS", "vs_5_1", &vs));
    TRY(compile(c, source, "PS", "ps_5_1", &ps));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = graphics_desc(c->graphics_root, vs, ps, depth);
    TRY(ID3D12Device_CreateGraphicsPipelineState(c->device, &desc, &IID_ID3D12PipelineState, (void **)pipeline));
done:
    release(vs); release(ps);
    return hr;
}
static void draw(Ps5D3D12 *c, UINT width, UINT height, const float color[4], float z) {
    float constants[8] = { color[0], color[1], color[2], color[3], z, 0, 0, 0 };
    D3D12_VIEWPORT viewport = {0, 0, (float)width, (float)height, 0, 1};
    ID3D12GraphicsCommandList_RSSetViewports(c->commands, 1, &viewport);
    ID3D12GraphicsCommandList_SetGraphicsRoot32BitConstants(c->commands, 0, 8, constants, 0);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(c->commands, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(c->commands, 3, 1, 0, 0);
}

int32_t ps5_d3d12_render(Ps5D3D12 *c, uint8_t *rgba, uint32_t width, uint32_t height) {
    if (!c || !rgba || !width || !height || width > 16384 || height > 16384) return E_INVALIDARG;
    HRESULT hr;
    ID3D12Resource *color = NULL, *depth = NULL, *readback = NULL;
    TRY(graphics_pipeline(c, 1));
    D3D12_HEAP_PROPERTIES heap = {0}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC desc = {0};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = width; desc.Height = height;
    desc.DepthOrArraySize = desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    TRY(ID3D12Device_CreateCommittedResource(c->device, &heap, 0, &desc, D3D12_RESOURCE_STATE_RENDER_TARGET, NULL, &IID_ID3D12Resource, (void **)&color));
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT64 bytes;
    ID3D12Device_GetCopyableFootprints(c->device, &desc, 0, 1, 0, &footprint, NULL, NULL, &bytes);
    TRY(buffer(c, bytes, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST, 0, &readback));
    desc.Format = DXGI_FORMAT_D32_FLOAT;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    D3D12_CLEAR_VALUE depth_clear = {0};
    depth_clear.Format = desc.Format; depth_clear.DepthStencil.Depth = 1;
    TRY(ID3D12Device_CreateCommittedResource(c->device, &heap, 0, &desc, D3D12_RESOURCE_STATE_DEPTH_WRITE, &depth_clear, &IID_ID3D12Resource, (void **)&depth));
    D3D12_CPU_DESCRIPTOR_HANDLE color_view = rtv(c, OFFSCREEN_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE depth_view = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(c->dsv_heap);
    ID3D12Device_CreateRenderTargetView(c->device, color, NULL, color_view);
    ID3D12Device_CreateDepthStencilView(c->device, depth, NULL, depth_view);
    TRY(begin(c));
    ID3D12GraphicsCommandList_SetPipelineState(c->commands, c->graphics_pipeline);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(c->commands, c->graphics_root);
    ID3D12GraphicsCommandList_OMSetRenderTargets(c->commands, 1, &color_view, FALSE, &depth_view);
    const float black[] = {0, 0, 0, 1}, red[] = {1, 0, 0, 1}, blue[] = {0, 0, 1, 1}, green[] = {0, 1, 0, 1};
    ID3D12GraphicsCommandList_ClearRenderTargetView(c->commands, color_view, black, 0, NULL);
    ID3D12GraphicsCommandList_ClearDepthStencilView(c->commands, depth_view, D3D12_CLEAR_FLAG_DEPTH, 1, 0, 0, NULL);
    D3D12_RECT scissor = {0, 0, (LONG)width, (LONG)height};
    ID3D12GraphicsCommandList_RSSetScissorRects(c->commands, 1, &scissor);
    draw(c, width, height, red, 0.25f);
    draw(c, width, height, blue, 0.75f);
    scissor.right = width / 2;
    ID3D12GraphicsCommandList_RSSetScissorRects(c->commands, 1, &scissor);
    draw(c, width, height, green, 0.125f);
    transition(c, color, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION source = {0}, destination = {0};
    source.pResource = color; source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    destination.pResource = readback; destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; destination.PlacedFootprint = footprint;
    ID3D12GraphicsCommandList_CopyTextureRegion(c->commands, &destination, 0, 0, 0, &source, NULL);
    TRY(submit(c));
    void *mapped = NULL;
    D3D12_RANGE range = {0, (SIZE_T)bytes}, empty = {0, 0};
    TRY(ID3D12Resource_Map(readback, 0, &range, &mapped));
    for (UINT y = 0; y < height; ++y) memcpy(rgba + (size_t)y * width * 4, (uint8_t *)mapped + footprint.Offset + (size_t)y * footprint.Footprint.RowPitch, (size_t)width * 4);
    ID3D12Resource_Unmap(readback, 0, &empty);
done:
    retire(c, readback); retire(c, depth); retire(c, color);
    return hr;
}

int32_t ps5_d3d12_attach_window(Ps5D3D12 *c, void *hwnd, uint32_t width, uint32_t height) {
    if (!c || !hwnd || !width || !height || width > 16384 || height > 16384) return E_INVALIDARG;
    HRESULT hr;
    IDXGISwapChain1 *swap = NULL;
    TRY(wait_idle(c));
    TRY(graphics_pipeline(c, 0));
    if (c->swapchain && c->hwnd != hwnd) return failure(c, E_INVALIDARG, "cannot rebind a swapchain to a different window");
    if (c->swapchain) {
        for (UINT i = 0; i < BACK_BUFFERS; ++i) { release(c->back_buffers[i]); c->back_buffers[i] = NULL; }
        TRY(IDXGISwapChain3_ResizeBuffers(c->swapchain, BACK_BUFFERS, width, height, DXGI_FORMAT_R8G8B8A8_UNORM, 0));
    } else {
        DXGI_SWAP_CHAIN_DESC1 desc = {0};
        desc.Width = width; desc.Height = height;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = BACK_BUFFERS;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        TRY(IDXGIFactory4_CreateSwapChainForHwnd(c->factory, (IUnknown *)c->queue, hwnd, &desc, NULL, NULL, &swap));
        TRY(IDXGISwapChain1_QueryInterface(swap, &IID_IDXGISwapChain3, (void **)&c->swapchain));
        TRY(IDXGIFactory4_MakeWindowAssociation(c->factory, hwnd, DXGI_MWA_NO_ALT_ENTER));
    }
    for (UINT i = 0; i < BACK_BUFFERS; ++i) {
        TRY(IDXGISwapChain3_GetBuffer(c->swapchain, i, &IID_ID3D12Resource, (void **)&c->back_buffers[i]));
        ID3D12Device_CreateRenderTargetView(c->device, c->back_buffers[i], NULL, rtv(c, i));
    }
    c->width = width; c->height = height;
    c->hwnd = hwnd;
done:
    release(swap);
    return hr;
}

int32_t ps5_d3d12_present(Ps5D3D12 *c, const float rgba[4]) {
    if (!c || !rgba || !c->swapchain) return E_INVALIDARG;
    HRESULT hr;
    UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(c->swapchain);
    ID3D12Resource *target = c->back_buffers[index];
    if (!target) return failure(c, E_FAIL, "swapchain backing");
    TRY(begin(c));
    transition(c, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
    D3D12_CPU_DESCRIPTOR_HANDLE view = rtv(c, index);
    ID3D12GraphicsCommandList_OMSetRenderTargets(c->commands, 1, &view, FALSE, NULL);
    ID3D12GraphicsCommandList_SetPipelineState(c->commands, c->present_pipeline);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(c->commands, c->graphics_root);
    D3D12_RECT scissor = {0, 0, (LONG)c->width, (LONG)c->height};
    ID3D12GraphicsCommandList_RSSetScissorRects(c->commands, 1, &scissor);
    draw(c, c->width, c->height, rgba, 0);
    transition(c, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
    TRY(submit(c));
    TRY(IDXGISwapChain3_Present(c->swapchain, 1, 0));
done:
    return hr;
}

int32_t ps5_d3d12_draw_spirv(Ps5D3D12 *c, const uint32_t *vertex, size_t vertex_count,
    const uint32_t *fragment, size_t fragment_count, const Ps5D3D12Draw *d, const uint8_t *indices, size_t index_bytes, uint8_t *rgba) {
    if (!c || !vertex || !fragment || vertex_count < 5 || fragment_count < 5 || !d || !rgba ||
        !d->width || !d->height || d->width > 16384 || d->height > 16384 || (!d->vertex_count && !d->index_count) || !d->instance_count ||
        (d->topology != D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST && d->topology != D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP) ||
        d->cull_mode < D3D12_CULL_MODE_NONE || d->cull_mode > D3D12_CULL_MODE_BACK || d->write_mask > 15) return E_INVALIDARG;
    if (d->index_count) {
        if (!indices || (d->index_element_bytes != 2 && d->index_element_bytes != 4) ||
            (uint64_t)d->index_count * d->index_element_bytes != index_bytes || index_bytes > 64u * 1024u * 1024u) return E_INVALIDARG;
    } else if (index_bytes || d->index_element_bytes || d->primitive_restart) return E_INVALIDARG;
    if (d->primitive_restart > 1 || (d->primitive_restart && d->topology != D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP)) return E_INVALIDARG;
    HRESULT hr;
    ID3DBlob *vs = NULL, *ps = NULL;
    ID3D12RootSignature *root = NULL;
    ID3D12PipelineState *pipeline = NULL;
    ID3D12Resource *color = NULL, *upload = NULL, *readback = NULL, *index_upload = NULL;
    TRY(compile_spirv(c, vertex, vertex_count, SpvExecutionModelVertex, 0, &vs));
    TRY(compile_spirv(c, fragment, fragment_count, SpvExecutionModelFragment, 0, &ps));
    TRY(guest_graphics_root(c, &root));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_desc = graphics_desc(root, vs, ps, 0);
    pipeline_desc.RasterizerState.CullMode = d->cull_mode;
    pipeline_desc.RasterizerState.FrontCounterClockwise = d->front_ccw != 0;
    pipeline_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = (UINT8)d->write_mask;
    pipeline_desc.IBStripCutValue = !d->primitive_restart ? D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED :
        d->index_element_bytes == 2 ? D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_0xFFFF : D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_0xFFFFFFFF;
    TRY(ID3D12Device_CreateGraphicsPipelineState(c->device, &pipeline_desc, &IID_ID3D12PipelineState, (void **)&pipeline));
    D3D12_HEAP_PROPERTIES heap = {0}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC desc = {0};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = d->width; desc.Height = d->height;
    desc.DepthOrArraySize = desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    TRY(ID3D12Device_CreateCommittedResource(c->device, &heap, 0, &desc, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&color));
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT64 bytes;
    ID3D12Device_GetCopyableFootprints(c->device, &desc, 0, 1, 0, &footprint, NULL, NULL, &bytes);
    TRY(buffer(c, bytes, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, 0, &upload));
    TRY(buffer(c, bytes, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST, 0, &readback));
    void *mapped;
    D3D12_RANGE empty = {0, 0}, entire = {0, (SIZE_T)bytes};
    TRY(ID3D12Resource_Map(upload, 0, &empty, &mapped));
    for (UINT y = 0; y < d->height; ++y) memcpy((uint8_t *)mapped + footprint.Offset + (size_t)y * footprint.Footprint.RowPitch, rgba + (size_t)y * d->width * 4, (size_t)d->width * 4);
    ID3D12Resource_Unmap(upload, 0, &entire);
    if (d->index_count) {
        TRY(buffer(c, index_bytes, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, 0, &index_upload));
        D3D12_RANGE written = {0, index_bytes};
        TRY(ID3D12Resource_Map(index_upload, 0, &empty, &mapped));
        memcpy(mapped, indices, index_bytes);
        ID3D12Resource_Unmap(index_upload, 0, &written);
    }
    D3D12_CPU_DESCRIPTOR_HANDLE view = rtv(c, OFFSCREEN_RTV);
    ID3D12Device_CreateRenderTargetView(c->device, color, NULL, view);
    TRY(begin(c));
    D3D12_TEXTURE_COPY_LOCATION source = {0}, destination = {0};
    source.pResource = upload; source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; source.PlacedFootprint = footprint;
    destination.pResource = color; destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    ID3D12GraphicsCommandList_CopyTextureRegion(c->commands, &destination, 0, 0, 0, &source, NULL);
    transition(c, color, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12GraphicsCommandList_SetPipelineState(c->commands, pipeline);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(c->commands, root);
    const uint32_t base_values[2] = {d->index_count ? (uint32_t)d->base_vertex : d->first_vertex, d->first_instance};
    ID3D12GraphicsCommandList_SetGraphicsRoot32BitConstants(c->commands, 0, 2, base_values, 0);
    ID3D12GraphicsCommandList_OMSetRenderTargets(c->commands, 1, &view, FALSE, NULL);
    D3D12_VIEWPORT viewport = {d->viewport[0], d->viewport[1], d->viewport[2], d->viewport[3], d->viewport[4], d->viewport[5]};
    D3D12_RECT scissor = {d->scissor[0], d->scissor[1], d->scissor[2], d->scissor[3]};
    ID3D12GraphicsCommandList_RSSetViewports(c->commands, 1, &viewport);
    ID3D12GraphicsCommandList_RSSetScissorRects(c->commands, 1, &scissor);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(c->commands, d->topology);
    if (d->index_count) {
        D3D12_INDEX_BUFFER_VIEW index_view = {ID3D12Resource_GetGPUVirtualAddress(index_upload), (UINT)index_bytes,
            d->index_element_bytes == 2 ? DXGI_FORMAT_R16_UINT : DXGI_FORMAT_R32_UINT};
        ID3D12GraphicsCommandList_IASetIndexBuffer(c->commands, &index_view);
        ID3D12GraphicsCommandList_DrawIndexedInstanced(c->commands, d->index_count, d->instance_count, 0, d->base_vertex, d->first_instance);
    } else ID3D12GraphicsCommandList_DrawInstanced(c->commands, d->vertex_count, d->instance_count, d->first_vertex, d->first_instance);
    transition(c, color, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    source = destination;
    destination.pResource = readback; destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; destination.PlacedFootprint = footprint;
    ID3D12GraphicsCommandList_CopyTextureRegion(c->commands, &destination, 0, 0, 0, &source, NULL);
    TRY(submit(c));
    TRY(ID3D12Resource_Map(readback, 0, &entire, &mapped));
    for (UINT y = 0; y < d->height; ++y) memcpy(rgba + (size_t)y * d->width * 4, (uint8_t *)mapped + footprint.Offset + (size_t)y * footprint.Footprint.RowPitch, (size_t)d->width * 4);
    ID3D12Resource_Unmap(readback, 0, &empty);
done:
    retire(c, index_upload); retire(c, readback); retire(c, upload); retire(c, color); retire(c, pipeline); retire(c, root); release(ps); release(vs);
    return hr;
}

int32_t ps5_d3d12_present_rgba(Ps5D3D12 *c, const uint8_t *rgba, uint32_t width, uint32_t height) {
    if (!c || !c->swapchain || !rgba || !width || !height || width > 16384 || height > 16384) return E_INVALIDARG;
    HRESULT hr;
    ID3D12Resource *upload = NULL;
    if (width != c->width || height != c->height) TRY(ps5_d3d12_attach_window(c, c->hwnd, width, height));
    UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(c->swapchain);
    ID3D12Resource *target = c->back_buffers[index];
    if (!target) return failure(c, E_FAIL, "swapchain backing");
    D3D12_RESOURCE_DESC desc = ID3D12Resource_GetDesc(target);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT64 bytes;
    ID3D12Device_GetCopyableFootprints(c->device, &desc, 0, 1, 0, &footprint, NULL, NULL, &bytes);
    TRY(buffer(c, bytes, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, 0, &upload));
    void *mapped;
    D3D12_RANGE empty = {0, 0}, entire = {0, (SIZE_T)bytes};
    TRY(ID3D12Resource_Map(upload, 0, &empty, &mapped));
    for (UINT y = 0; y < height; ++y) memcpy((uint8_t *)mapped + footprint.Offset + (size_t)y * footprint.Footprint.RowPitch, rgba + (size_t)y * width * 4, (size_t)width * 4);
    ID3D12Resource_Unmap(upload, 0, &entire);
    TRY(begin(c));
    transition(c, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_TEXTURE_COPY_LOCATION source = {0}, destination = {0};
    source.pResource = upload; source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; source.PlacedFootprint = footprint;
    destination.pResource = target; destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    ID3D12GraphicsCommandList_CopyTextureRegion(c->commands, &destination, 0, 0, 0, &source, NULL);
    transition(c, target, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT);
    TRY(submit(c));
    TRY(IDXGISwapChain3_Present(c->swapchain, 1, 0));
done:
    retire(c, upload);
    return hr;
}

uint64_t ps5_d3d12_validation_errors(Ps5D3D12 *c) {
    if (!c || !c->messages) return 0;
    UINT64 count = ID3D12InfoQueue_GetNumStoredMessages(c->messages), errors = 0;
    for (UINT64 i = 0; i < count; ++i) {
        SIZE_T bytes = 0;
        if (FAILED(ID3D12InfoQueue_GetMessage(c->messages, i, NULL, &bytes))) continue;
        D3D12_MESSAGE *message = malloc(bytes);
        if (!message) return UINT64_MAX;
        if (SUCCEEDED(ID3D12InfoQueue_GetMessage(c->messages, i, message, &bytes)) && message->Severity <= D3D12_MESSAGE_SEVERITY_ERROR) {
            ++errors;
            fprintf(stderr, "[d3d12 validation] %s\n", message->pDescription);
        }
        free(message);
    }
    return errors;
}
