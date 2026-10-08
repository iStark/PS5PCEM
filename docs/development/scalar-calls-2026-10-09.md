# Scalar shader calls — October 9, 2026

`S_SWAPPC_B64` and `S_CALL_B64` now execute bounded shader subroutines through
PS5PCEM's shared RDNA2 and Vulkan paths. Previously SWAPPC only worked with a
NULL destination, as a SETPC continuation; calls that retained a return address
were unsupported. The change also links a verified external AGC fetch shader
to its caller. It does not establish a new game milestone or FPS result.

## Behavior

- SOP1 opcode `0x21` decodes SWAPPC with its source pair and two-word link
  destination. The existing NULL-destination SETPC alias remains intact.
- SOPK opcode `0x16` decodes CALL with target
  `PC + 4 + sign_extend(SIMM16) * 4`, including backward calls.
- Both instructions save the full next-instruction address in the destination
  SGPR pair. A matching `S_SETPC_B64` returns to the instruction following the
  call. CALL itself preserves SCC and EXEC.
- Local SWAPPC targets can be resolved from GETPC and a full-width immediate
  add/subtract sequence. The target is captured independently of link writes.
- A referenced callee after ENDPGM is decoded through its matching return,
  within the existing allocation/instruction bounds. An ordinary hardware
  continuation still stops before trailing metadata.
- The control-flow graph contains explicit call and return edges. Callees share
  the caller's register state and use the existing bounded SPIR-V dispatcher;
  unsupported calls cannot enter the linear control-flow fallback.
- Host scalar resource discovery follows calls and returns, including resources
  initialized inside callees. Static calls use the overall resource-walk budget
  instead of the older eight-SETPC continuation allowance.

External fetch linking requires the call's unchanged USER_DATA pair to match
AGC's registered fetch address. Fetch code is decoded to its returning SETPC,
which must read the caller's link pair. The body is attached under separate
instruction PCs and retains a real return edge. Analysis caching distinguishes
ordinary programs from fetch bodies, and legacy fetch insertion cannot replace
a local subroutine's return.

## Supported subset

Each call owns a distinct, even-aligned ordinary SGPR pair from `s0:s1` through
`s104:s105`, with exactly one matching return. Callee regions must be nested or
disjoint. The verifier rejects recursion, shared/clobbered/escaping links,
unaligned links, targets inside literals, cross-region branches/fallthrough and
unresolved dynamic calls. Other dynamic SETPC transfers in a static-call
program are also rejected. An external fetch body cannot itself contain calls,
GETPC or additional SETPC transfers.

The full register tuples used by scalar loads and resource descriptors are
checked for overlap with links. This is a conservative static subset, not a
general indirect call stack. Existing dispatcher and resource-walk limits still
apply. Programs without calls retain their existing GETPC fallback behavior.

## Validation

```powershell
zig build vulkan-smoke -Doptimize=ReleaseSafe -- --scalar-calls
zig build test-rdna2 -Dtest-filter="scalar calls" -Doptimize=ReleaseSafe
zig build test-gpu -Doptimize=ReleaseSafe
zig build test-vulkan -Doptimize=ReleaseSafe
```

- The RTX 3070 Ti probe passes **42 dispatches and 21,504 exact output-word
  comparisons**, with the Khronos validation layer enabled. Five local-call
  layouts cover forward SWAPPC, forward/backward CALL, a callee after ENDPGM,
  and nested mixed calls. Each runs with 32, 64 and 128 invocations, both with
  full EXEC and with only odd lanes enabled. Inactive output remains untouched.
- Twelve additional cases execute the external-fetch linking result in compute
  kernels, with wave32/wave64, the same invocation counts and EXEC masks. This
  makes fetched values and return-to-caller stores observable; it is not a
  live-game graphics capture.
- **5/5 focused RDNA2 tests** and **3/3 focused GPU-analysis tests** pass.
  Translation covers compute, vertex and fragment stages through both decoded
  instructions and the typed IR/SSA path. Tests verify link-address carry across
  32 bits, unchanged SCC/EXEC, malformed-call rejection, pointer matching and
  preservation of legacy continuations.
- The complete GPU-analysis suite passes **259/259**. Its existing hardware
  continuation test caught premature stopping after a prior SETPC; the stopping
  rule now distinguishes an actual ENDPGM and a paired subroutine return.
- The complete Vulkan module suite passes **232/232**. The existing native
  LS/HS indexed-tessellation probe also passes: triangle and quad control
  points, 16/32-bit indices, base vertex, instance IDs, high USER_DATA SGPRs,
  wave boundaries, LDS and partial groups retain their expected results.
- The complete RDNA2 suite passes **271/281**, compared with **267/277** at
  parent `6dff8e3`. The same ten tests fail and the existing failing FLAT-load
  test still reports one leak. These baseline failures are not reported as fixed.

Logs are retained as `out/scalar-calls-*-20261009.log`, with installation and
test evidence under `out/scalar-calls-20261009/`.

## Installed runner

The ReleaseFast runner build completed all nine steps. `zig-out/bin/game-run.exe`
and its matching PDB are updated; the previous pair is retained as
`out/scalar-calls-20261009/previous-game-run.*`. The installed runner's
no-argument CLI check prints usage and returns the expected exit code 1.

The executable is signed with the existing **Artur Strazewicz / PS5PCEM**
certificate and a DigiCert timestamp. Windows continues to report the existing
certificate chain's untrusted root; the trust store was not changed.
Installed SHA-256:
`C776993416DB4E362BF0DC347E8582D05851FA44183BA7C1C5944F906067814B`.

## References

The local AnyPS5 checkout at `04477932167b27525d8c37e69bb9eb7a50048fe4`
provided reference call-region rules and execution fixtures:
[SWAPPC fetch calls](https://github.com/boykopovar/AnyPS5/commit/c48e0197),
[bounded CALL execution](https://github.com/boykopovar/AnyPS5/commit/ee0b1109),
and [link-lifetime checks](https://github.com/boykopovar/AnyPS5/commit/4d2917e6).
PS5PCEM implements these rules in its own decoder, CFG, scalar resource walker,
fetch linker and SPIR-V builder. Validation here uses the host Vulkan GPU;
no new console-hardware measurement is claimed.
