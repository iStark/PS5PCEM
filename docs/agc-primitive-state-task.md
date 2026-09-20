# AGC primitive-state update task

Implement `sceAgcUpdatePrimState` (`Y3ymLfZ1384`) and verify the updated
primitive type through the existing register writers, command processor, and
draw-state decoding. The export currently resolves to `agc.accept`, so callers
receive success without changing their primitive-state arrays.

## Scope

- Establish the guest ABI for the two optional register arrays and primitive
  type. Keep the existing `sceAgcCreatePrimState` layout and hull/geometry
  handling compatible. Do not reverse the global export-registration order.
- Update the primitive-type field in the uconfig array and the GS output-type
  field in the context array where the enabled shader stages permit it. Preserve
  register offsets and unrelated bits. Use explicit point, line, triangle, and
  rectangle mappings; do not assume input topology and GS output topology share
  enum values.
- Check how geometry and tessellation enable bits affect ownership of the
  output type. Changing an input primitive must not overwrite a real geometry
  shader's or tessellator's output topology.
- Validate writable output spans before modifying either array. Define and
  test the behavior for null arrays, invalid primitive values, and truncated
  memory. Keep error results distinguishable from a successful update.
- Replace only this export's placeholder registration. Register the real
  handler alongside the code that constructs the arrays, avoiding duplicate NID
  entries and import cycles.

## Verification

Tests must obtain the handler through `hle.registerAll`. Use independently
specified input/output words, including nonzero bits outside the fields being
updated. Cover each primitive family, both stage-ownership cases, and all
supported null-array combinations.

Add an integration test that creates primitive state, updates it, emits the
arrays through registered indirect-register writers, and executes a draw. The
draw callback must see the updated input topology and preserved stage state.
Changing the primitive type twice in one command stream must affect the two
draws separately. Verify that the Vulkan pipeline selection consumes this
state; if a guest topology cannot be rendered yet, describe that limitation
instead of adding an unrelated approximation.

Run the relevant HLE/GPU tests and the normal ReleaseFast build. Compare any
full-suite failures by name against the unchanged baseline. A menu-only Big
Helmet Heroes run checks regression, but only proves operation coverage if the
new helper is actually called. Use explicit manual input, one game process at
a time, and close it after the capture. Record the executable hash and measure
FPS without detailed tracing.

## Delivery

Provide one focused commit with an English Conventional Commit message, a
short account of the ABI evidence and remaining assumptions, and test results.
Do not bundle `GetGsOversubscription`, context-state changes, or shader-fusion
changes into this task. Oversubscription should be a separate task with its
own allocation analysis and tests; writing scheduling registers alone does not
establish a host Vulkan FPS improvement.
