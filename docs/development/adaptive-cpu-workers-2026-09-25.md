# Adaptive CPU preparation and compiler workers, 2026-09-25

The previous resource helper ran scalar evaluation and storage checkpoints
sequentially on a thread assigned to one shader stage. These are now separate
jobs in a shared queue: up to four jobs from pixel and vertex stages, serviced
by up to four CPU helpers. With one helper, both stages remain eligible.

The new common queue also backs the existing pipeline compiler. Its foreground
priority, FIFO ordering within priority, serial startup-failure fallback and
joined shutdown remain. A lower live limit parks excess workers between jobs;
it does not just change the number of threads created on the next enqueue.

## Adaptive admission

The runner enables adaptive admission for both pools by default. Each starts
with one worker; the automatic ceiling depends on logical CPU count and is at
most four per pool. On this 16-logical-CPU machine both ceilings are four. The
pools do not create their entire ceiling up front. Existing command-decode and
copy helpers retain their separate controls.

Measured elapsed job time, queue delay, backlog and idle intervals control the
admitted concurrency. Adjustments are incremental, at least 100 ms apart, with
500 ms idle decay on subsequent submission. Work averaging below 25 us does
not cause growth. Shaders below the established 256-step eligibility threshold
still run inline. This is a bounded queue policy, not a frame-time optimizer or
a system-wide CPU/GPU utilization controller. It cannot guarantee higher FPS.

- `PS5_GPU_RESOURCE_WORKERS=0..4`: fixed resource limit; zero disables offload.
- `PS5_GPU_COMPILER_WORKERS=1..4`: fixed compiler limit.
- An explicit limit disables adaptation only for that pool.
- `PS5_GPU_ADAPTIVE_WORKERS=0`: fixed two-worker defaults, subject to overrides.

The pool profile lines expose admission, created threads, actual peak overlap,
queue/job duration and increases/decreases. Reading diagnostics does not change
controller decisions. Idle threads sleep instead of being destroyed/recreated.

## Ordering and ownership

Only the renderer owner reads live guest memory, captures the original walk,
validates snapshots through normal publication callbacks and binds Vulkan
resources. Helper jobs read immutable captures and copied bindings, with a
separate missing-read/error flag per job. Concurrent snapshot readers never
modify shared state. Changed or incomplete captures use serial evaluation.

Consumers wait for the specific result they need. Every draw exit still joins
both jobs before releasing instructions, bindings or scratch. Queue shutdown
waits for callbacks as well as their result events. No jobs cross draw lifetime
boundaries. There is no new Vulkan queue, concurrent Vulkan resource mutation,
guest-memory access from helpers, or title-specific eligibility rule.

## Validation

Artifacts are under `out/adaptive-workers-20260925/`. GPU/Vulkan unit tests
passed 410/410 (`tests2.log`), including serial equality for resource results
with one, two, four and adaptive workers, snapshot invalidation, owner-only
reads, thread-creation failure, draining shutdown, deterministic policy growth
and shrinkage, and lowering a limit while jobs are blocked before raising it
to execute four independent jobs concurrently.

The `--resource-workers` native Vulkan probe passed with off, fixed 1/2/4,
and adaptive modes, including changed textures/constants, descriptor register
lifetimes, storage writes, queued attachment snapshots and resized attachments.

Both `--pipeline-warmup` and `--pipeline-warmup-adaptive` passed on the 15-module
Tetris catalog with zero compile failures and zero retained warmup pipelines.
Both observed two simultaneous driver calls. The adaptive ceiling was four;
this checks real compiler integration, not a compilation-speed comparison.
These probes ran before any live game was started.

The broader historical smoke failure described in the first resource-worker
report is not claimed to be resolved by this change.

## Final binary and Quake II runs

`zig build build-game-run vulkan-smoke -Doptimize=ReleaseFast -j2 --summary all
-- --resource-workers` completed successfully, 11/11 build steps. The installed
`zig-out/bin/game-run.exe` was written at 20:51:09 local time, 38,786,560 bytes.
SHA-256: `E8B65D529E8535D51E68B7C1505EFBE5408BD9A3ADDE6BF928093DDAFA584C27`.

Two roughly three-minute Quake II attract-demo runs used this identical EXE,
controller-only input and no synthetic button presses. No build or native GPU
probe ran alongside either game. Both runs were deliberately closed by the
agent after sampling; neither ended with a detected panic, device loss or
backend rejection. The captured automatic-mode frame shows lit NPCs, weapon,
hand and world geometry.

The automatic run selected two resource workers, with two upward adjustments
and one downward adjustment. Its last profile sample, flip 8520, records
16,644 submitted/consumed results, zero fallbacks, 1,046 ms summed worker time
and 262 ms summed owner join time. Peak concurrent resource jobs was two.
The compiler stayed at one worker in this already mostly cached title.

Overall process CPU averaged 5.09% of 16 logical CPUs with automatic resource
workers and 4.90% with resource offload disabled (20–90 s sampling window).
The hottest threads averaged 70.34% and 68.15% of one logical CPU respectively.
Most CPU time is still concentrated in the renderer owner; this change does
not remove its buffer staging, descriptor binding or synchronization costs.

Attract-demo scenes differed, so their FPS distributions do not establish a
speedup or a regression. For example, warmed samples with fewer than 200 draws
had median 10 ms / 57 draws with automatic workers and 11 ms / 59.5 draws with
offload disabled; the 200–399 group had 19 ms / 299 draws versus 18.5 ms / 267.5
draws. These are different workloads, not paired frames. The complete data is
in `comparison-quake.json`; no stable FPS gain is claimed.

Only these Quake II scenes and the additional menu check below were exercised
in this comparison. A subsequent Yotei run with these workers and guest game
presets is documented in [game-presets-2026-09-26.md](game-presets-2026-09-26.md);
it does not isolate the workers' performance impact.


## Short-shader check and handoff

Jets 'n' Guns 2 reached its menu and ran for 90 seconds on the same EXE with
automatic defaults. The menu rendered normally; there were no resource-worker
jobs and no detected panic, device loss or backend rejection. The eligible
warmed frame sample had median 27 ms, 80 draws and 11 ms CPU draw time, matching
the earlier menu measurement. This is a menu check, not gameplay validation.

That run was deliberately closed and Quake II restarted in automatic mode,
without synthetic input, under `quake-final-auto/`. The final game is left
running for the user at that handoff. Source formatting and `git diff --check`
pass. Later native runs and the newer binary are recorded in the report linked
above.
