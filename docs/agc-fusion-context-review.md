# Shader fusion and context-state review

Reviewed on September 21, 2026:

- `dfcdb98948e1a60a6d58934a6fc92945d9f39f15`: resource merging and the second
  shader-fusion export.
- `321fe322719f4b4756da1fee7c83cbfb59dca427` / `e405f7f360773be1e4650931774bc68f65ac4162`:
  context-state writers, size queries, and execution. These commits have identical
  trees. Their duplicate merge was replaced by `15221fa0ede8648078b3591a5b78f2efb919319e`,
  with the same tree and one parent.

## Corrections

The reallocating fusion export could discard required shared VGPRs. Two halves
each requesting 32 private and 8 shared registers produced 32 private and zero
shared registers. The original calculation subtracted the smaller total and
divided the remainder by 64. It now subtracts the merged private allocation
from the larger total and rounds the remainder up to eight-register blocks.
For example, demands of 32+8 and 16+32 become 32+16. The other export retains
its maximum-shared-count behavior and front user-data pointer.

The allocation units were checked against the public
[LLVM AMDGPU register documentation](https://llvm.org/docs/AMDGPUUsage.html#amdgpu-amdhsa-compute-pgm-rsrc3-gfx10-table).
The merge rule follows the requirement that the resulting allocation covers
both halves; this does not establish the exact behavior of every firmware
version. Shared-register test cases now use wave64, and the tests independently
check required capacity, symmetry, rounding, private coverage, and a near-limit
allocation for GS and HS.

Context-stack overflow and underflow previously only incremented a counter and
printed a message. Execution continued, so a Pop after a refused Push could
consume an outer frame and a later draw could use another pass's state. The
executor now returns `ContextStateStackFault`, and the scheduler discards that
submission before its remaining operations run. The current context and saved
frames remain intact. The four-frame capacity is documented as an emulator
limit, not a verified hardware limit.

The registered context writer/GetSize pairs and their packet boundaries are
retained. Context operations still affect only context registers. Shader,
uconfig, index, predicate, and synchronization state remain outside the saved
file. The backend copies draw state for deferred work, so a later context Pop
does not replace an already-recorded draw's state.

## Verification

- Both new regression tests failed before the corrections: shared allocation
  was lost and a faulted context submission completed instead of failing.
- HLE: **473/473**. GPU: **208/208**. Full suite: **1275/1286 passed**, one
  skipped, ten failed. All ten failure names match the unchanged SPIR-V
  baseline; the same module also reports its existing allocator leak.
- The scratch test now requires an actual resource-register change, verifies
  mutation without scratch, and checks that a scratch-backed merge leaves the
  entire back array unchanged. A draw callback now records the restored context
  value at draw time instead of checking only the final register state.
- Scheduler tests cover overflow for both Push and PushClear, underflow, no
  subsequent Pop or draw, preserved context, and removal of the failed
  submission. Existing size, nesting, queue-isolation, and wait/resume tests pass.
- `zig build build-game-run -Doptimize=ReleaseFast` passed. Executable SHA256:
  `0b86271bf0c8fc12e4123cc532e1f83e2d543d19f3cf04bf6ea27e62f1722d3d`.

The build used the reviewed source changes plus independent, comment-only edits
in `audio.zig` and `agc_submit.zig`. Those edits are outside this review commit.
The launch artifact records the full source diff and executable hash.

## Menu regression check

A fresh Big Helmet Heroes launch used `PS5_INPUT_MODE=controller`, detailed
tracing disabled, and one game process. The actual-window images matched the
maintainer-approved menu reference in scenery, characters, colors, and lighting.
The inspected sequence contains 100 captures over 10.68 seconds, spanning 37
presented frame numbers; it showed no disappearing objects, blue surfaces, or
day/night lighting changes. Initial and final full-size captures also matched.

A separate 29.89-second measurement counted 102 presented frames: **3.41 FPS**,
median frame interval **290.69 ms**. This is within the previously observed menu
range and is not evidence of an FPS improvement or long-run stability.
Gameplay was not entered. The process was stopped after the check, and no
`game-run.exe` processes remained.

The menu is a regression check, not complete coverage of either AGC feature.
The registered-export and scheduler tests exercise the resource-allocation and
context-stack cases described above. Other titles and gameplay remain untested
by this review.

Local artifacts are under `out/agc-reviewed-20260921-bhh/`; test logs are
`out/agc-321fe32-baseline-tests.log`, `out/agc-review-regressions-before.log`,
and `out/agc-review-fixed-tests.log`. The build log is
`out/agc-review-game-build.log`.
