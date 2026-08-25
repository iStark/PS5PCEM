# `runtime` — end-to-end composition

[← Documentation index](../README.md) · [Project status](../project-status.md)

[src/runtime/root.zig](../../src/runtime/root.zig) owns the dependency direction that
does not belong in any lower-level module. It creates one `memory.AddressSpace`
with the sparse direct-memory backing store, connects it to libkernel, registers
all HLE exports, owns the process TLS and guest-export registries, and adapts all
three sources to `loader.Resolver`. Exact library/module/version metadata is used
first; identifier-only lookup remains the documented fallback for incomplete
module metadata. [src/runtime/module_graph.zig](../../src/runtime/module_graph.zig)
recursively indexes adjacent `.prx`/`.sprx` files, follows both `DT_NEEDED` and
PS5 needed-module declarations, maps the complete reachable graph, and only then
relocates it. After all guest exports are published, resolved imports add
provider edges that filenames alone cannot express (for example a short
`libc.prx` filename exporting the `libSceLibcInternal` module). Explicit preload
roots extend that graph for plugins the title will request later. Missing files
remain firmware/HLE dependencies. The resulting module list is already in
dependency-first initializer order and publishes per-module export ownership
for `sceKernelDlsym`. Optional graph diagnostics report every unresolved strong
import in the node that stops linking; the `graph-info` tool enables them by
default.

`game-run` continues from that verified graph, creates the optional Win32 Vulkan
presentation session, installs it behind the live AGC scheduler, initializes
the native CPU bridge and enters the title while reporting contained guest
faults with the active initializer, registers, stack words, and relocation
context. Its
`--app0 <directory>` option lets a sparse patched executable use the complete
content tree from another directory. Position-dependent executables which
access the PS5 null/low-address window still need address translation or
instruction fixups on Windows, where those pages cannot be identity-mapped.

```zig
const runtime = @import("runtime");

var emu = runtime.Runtime{};
try emu.init(allocator);
defer emu.deinit();

var graph = try emu.loadModuleGraph(io, "game/eboot.bin", .{});
defer graph.deinit();

try emu.enableNativeCpuDispatcher(io);

const initial = try emu.prepareInitialThread("main");
defer emu.releaseInitialThread(initial.handle) catch {};

const result = try emu.dispatchProcess(initial, graph.executable(), .{
    .modules = graph.modules(),
    .entry = .{
        .image_name = "eboot.bin",
        .arguments = &.{"--safe"},
    },
});
std.debug.print("process returned 0x{x}\n", .{result});
```

`enableNativeCpuDispatcher` currently succeeds only on Windows x86-64 with
user-mode FS-base instructions enabled. `dispatchProcess` follows the startup
order executable preinit → dependency-first module init → executable init, with
per-image guards preventing a second initializer run. It then uses
[src/runtime/process.zig](../../src/runtime/process.zig) to place the PS5 0x20-byte
entry parameter structure and up to three inline `argv` pointers at the top of
the prepared guest stack. The structure address is passed in RDI, the optional
exit handler in RSI, and the native bridge enters with the corresponding AMD64
stack alignment.

`Runtime.init` is intentionally in-place. Libkernel retains a pointer to the
address space, so returning a Runtime value from an initializer could move it
and leave that pointer dangling. Loaded modules or graphs must be destroyed
before the runtime; their `deinit` methods unregister guest/TLS exports and
decommit module pages while leaving the outer guest windows owned until runtime
teardown.

---
