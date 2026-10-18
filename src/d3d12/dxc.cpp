// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

// DXC has a C++ COM API. Keep its objects and DLL lifetime behind a small C ABI;
// never reinterpret an IDxcBlob as an ID3DBlob (their interface IDs differ).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
// Use Clang's UUID attribute support for Microsoft's header; MinGW's template
// replacement only has specializations for interfaces in its own headers.
#ifdef __uuidof
#undef __uuidof
#endif
#include <inc/dxcapi.h>
#include <cstdio>
#include <cstring>
#include <new>
#include "dxc.h"

struct Ps5Dxc {
    HMODULE compiler_lib = nullptr, validator_lib = nullptr;
    IDxcCompiler3 *compiler = nullptr;
    IDxcValidator *validator = nullptr;
};

static HMODULE adjacent_library(const wchar_t *name) {
    wchar_t path[32768];
    DWORD length = GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
    if (!length || length >= ARRAYSIZE(path)) { SetLastError(ERROR_INSUFFICIENT_BUFFER); return nullptr; }
    wchar_t *end = wcsrchr(path, L'\\');
    if (!end || size_t(end + 1 - path) + wcslen(name) >= ARRAYSIZE(path)) {
        SetLastError(ERROR_BAD_PATHNAME); return nullptr;
    }
    wcscpy(end + 1, name);
    return LoadLibraryExW(path, nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
}

void ps5_dxc_destroy(Ps5Dxc *c) {
    if (!c) return;
    if (c->compiler) c->compiler->Release();
    if (c->validator) c->validator->Release();
    if (c->compiler_lib) FreeLibrary(c->compiler_lib);
    if (c->validator_lib) FreeLibrary(c->validator_lib);
    delete c;
}

int32_t ps5_dxc_create(Ps5Dxc **out, char *error, size_t error_size) {
    *out = nullptr;
    auto c = new (std::nothrow) Ps5Dxc;
    if (!c) return E_OUTOFMEMORY;
    HRESULT hr = S_OK;
    const char *operation = "load adjacent dxil.dll (keep the shipped DXC DLLs beside the executable)";
    c->validator_lib = adjacent_library(L"dxil.dll");
    if (!c->validator_lib) hr = HRESULT_FROM_WIN32(GetLastError());
    if (SUCCEEDED(hr)) {
        operation = "load adjacent dxcompiler.dll";
        c->compiler_lib = adjacent_library(L"dxcompiler.dll");
        if (!c->compiler_lib) hr = HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(hr)) {
        operation = "create DXIL validator";
        auto create = reinterpret_cast<DxcCreateInstanceProc>(GetProcAddress(c->validator_lib, "DxcCreateInstance"));
        hr = create ? create(CLSID_DxcValidator, __uuidof(IDxcValidator), reinterpret_cast<void **>(&c->validator)) : E_NOINTERFACE;
    }
    if (SUCCEEDED(hr)) {
        operation = "create DXC compiler";
        auto create = reinterpret_cast<DxcCreateInstanceProc>(GetProcAddress(c->compiler_lib, "DxcCreateInstance"));
        hr = create ? create(CLSID_DxcCompiler, __uuidof(IDxcCompiler3), reinterpret_cast<void **>(&c->compiler)) : E_NOINTERFACE;
    }
    if (FAILED(hr)) {
        std::snprintf(error, error_size, "%s failed (HRESULT 0x%08lx)", operation, static_cast<unsigned long>(hr));
        ps5_dxc_destroy(c);
    } else *out = c;
    return hr;
}

int32_t ps5_dxc_compile(Ps5Dxc *c, const char *source, const char *profile,
    Ps5DxcCode *out, char *error, size_t error_size) {
    *out = {};
    wchar_t target[16];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, profile, -1, target, ARRAYSIZE(target))) return E_INVALIDARG;
    // Validation remains enabled. No include handler: generated HLSL is self-contained.
    const wchar_t *args[] = { L"-E", L"main", L"-T", target, L"-HV", L"2018", L"-Ges", L"-O3" };
    DxcBuffer input = { source, std::strlen(source), DXC_CP_UTF8 };
    IDxcResult *result = nullptr;
    IDxcBlob *code = nullptr;
    IDxcOperationResult *validation = nullptr;
    HRESULT hr = c->compiler->Compile(&input, args, ARRAYSIZE(args), nullptr, __uuidof(IDxcResult), reinterpret_cast<void **>(&result));
    if (SUCCEEDED(hr)) {
        HRESULT status = E_FAIL;
        hr = result->GetStatus(&status);
        if (SUCCEEDED(hr)) hr = status;
    }
    if (FAILED(hr) && result) {
        IDxcBlobEncoding *messages = nullptr;
        result->GetErrorBuffer(&messages);
        std::snprintf(error, error_size, "DXC main/%s: %.*s", profile,
            messages ? static_cast<int>(messages->GetBufferSize()) : 0,
            messages ? static_cast<const char *>(messages->GetBufferPointer()) : "");
        if (messages) messages->Release();
    }
    if (SUCCEEDED(hr)) hr = result->GetResult(&code);
    if (SUCCEEDED(hr)) hr = c->validator->Validate(code, DxcValidatorFlags_Default, &validation);
    if (SUCCEEDED(hr)) {
        HRESULT status = E_FAIL;
        hr = validation->GetStatus(&status);
        if (SUCCEEDED(hr)) hr = status;
        if (FAILED(hr)) {
            IDxcBlobEncoding *messages = nullptr;
            validation->GetErrorBuffer(&messages);
            std::snprintf(error, error_size, "DXIL validation %s: %.*s", profile,
                messages ? static_cast<int>(messages->GetBufferSize()) : 0,
                messages ? static_cast<const char *>(messages->GetBufferPointer()) : "");
            if (messages) messages->Release();
        }
    }
    if (SUCCEEDED(hr)) {
        out->object = code;
        out->bytes = code->GetBufferPointer();
        out->size = code->GetBufferSize();
    } else {
        if (code) code->Release();
        if (!error[0]) std::snprintf(error, error_size, "DXC %s failed (HRESULT 0x%08lx)", profile, static_cast<unsigned long>(hr));
    }
    if (validation) validation->Release();
    if (result) result->Release();
    return hr;
}

void ps5_dxc_release(Ps5DxcCode *code) {
    if (code->object) static_cast<IDxcBlob *>(code->object)->Release();
    *code = {};
}
