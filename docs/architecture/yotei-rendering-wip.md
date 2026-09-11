# Yotei rendering investigation snapshot — 2026-09-11

This branch preserves the four outstanding source files reviewed against
`e216f39` (`perf(rdna2): alternate scratch banks for wave exchanges`). It is a
recovery point for the rendering investigation, not a verified release or an
FPS improvement claim. The source changes are preserved as reviewed.

## Preserved changes

- `src/gpu/tessellation.zig` and its export in `src/gpu/root.zig`: decode the
  merged LS/HS entry state and assemble the local and hull stages into a compute
  prepass. The current path supports nonindexed quad patches with four input
  and output control points, at most 64 patches per group and 32 KiB offchip
  group storage. LS user data and temporary-register assumptions are limited
  to the implemented ABI.
- `src/vulkan/backend.zig`: run that prepass, stage the real tessellation-factor
  buffer and supply domain-shader inputs to the existing Vulkan tessellator.
  `native_tessellation` is an exported diagnostic toggle, false by default.
- The same backend contains fragment uniform specialization behind the
  separate `graphics_uniform_specialization` toggle, also false by default.
  Historical replay notes report `UnsupportedSampledImage` with this
  experiment; they establish neither a successful fix nor a speedup.
- Storage/vertex capture switches select diagnostic dumps by program, frame
  and address. They are disabled by default. Captures perform GPU readbacks
  and file writes and can propagate errors into the draw/dispatch path.
- `src/vulkan_smoke.zig`: formatting and ordering of the existing GDS command
  handlers only. Later concurrent edits to the buffer-content-cache probe are
  outside this snapshot.

## Latest identified run

The local `run-logs/yotei-menu-20260909/launch.json` records a run started at
2026-09-11 20:37:10 +03:00, PID 25252, from
`runtime-wave-banks/bin/game-run.exe`, labelled `e216f39+native-tessellation-wip`.
Its SHA-256 was independently matched to the executable:

`6F7865F1489F1E74CD447C4E1B80896E319212D2CDBE75C941E52F217CB25B9D`

The record says `nativeTessellation: true`. The corresponding enable script
sets the exported native-tessellation flag and checks that graphics uniform
specialization remains off. The process had exited when this review checked
it, so its final in-memory toggle value could not be read. This record does
not prove that a particular later scene executed tessellated draws.

The user reports correct rendering in a recent run. Its exact association
with this executable remains to be confirmed. Preserve this source state and
the identified binary before removing any of the experimental paths.

## Fresh checks on the preserved source

- ReleaseSafe build of `src/vulkan_smoke.zig`: passed.
- Filtered GPU-module unit run for `tessellation`: passed (root test and the
  register-decoding/compute-state-preservation test).
- GPU `--tessellation-inputs`: passed, covering fractional quad factors, patch
  IDs across groups, offchip offsets, changed factors and zero/OOB culling.

The GPU probe exercises the existing tessellation interfaces. It does not
validate the complete native LS/HS integration or visual correctness in the
game. This review did not enable Vulkan SDK validation, run the full test
suite, relaunch the game or measure FPS.

Historical investigation and replay evidence remain under the ignored local
`run-logs/yotei-menu-20260909/` directory, particularly
`wave64-gds-investigation.md` and `validation-native-lshs-builder.log`. Those
notes include both successful probes and unresolved graphics problems; they
must not be treated as fresh regressions in the user's latest run. Captures,
game data and machine-specific launch scripts are not part of this commit.
