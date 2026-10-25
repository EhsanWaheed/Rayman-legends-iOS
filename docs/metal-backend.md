# Native Metal backend for the ReXGlue SDK

Goal: run Rayman Legends (and any ReXGlue title) on Apple GPUs without Vulkan or MoltenVK in between — the
Xenos GPU emulation talking to Metal directly — for lower CPU overhead, less heat, and access to what Apple
GPUs do best (tile memory, Metal 4's command model, pipeline binary archives). The MoltenVK path stays working
and selectable until the Metal path matches it everywhere.

## What changes and what doesn't

| Layer | Today | With the Metal backend |
| --- | --- | --- |
| CPU | PowerPC recompiled to ARM64 ahead of time | unchanged |
| GPU commands (PM4), Xenos state | emulated by the SDK's command processor | unchanged (shared base classes) |
| Shaders | Xenos microcode → SPIR-V → (MoltenVK: SPIRV-Cross → MSL at pipeline creation) | Xenos microcode → SPIR-V → MSL once, cached; Metal libraries and pipelines built by us, kept in binary archives |
| API | Vulkan objects, MoltenVK translating every call, descriptor sets, barriers | Metal objects directly: encoders, argument buffers / Metal 4 argument tables, residency sets |
| EDRAM | host render targets + transfers/resolves (Vulkan) | the same model on Metal first (proven, carries every optimisation so far), then tile-memory work |
| Presentation | Vulkan swapchain over CAMetalLayer + MetalFX via VK_EXT_metal_objects | CAMetalLayer drawables and MetalFX directly |

## Source

The SDK's GPU code and Xenia Canary share their lineage. [xenia-alloy](https://github.com/DarthMDev/xenia-alloy)
(BSD, maintained in 2026) has a native Metal backend on the current Canary core: command processor, render
target cache (EDRAM dumps, transfers, resolves as Metal compute/render kernels), texture cache, shared memory,
primitive processor, presenter. Its main shader path goes through DXBC → DXIL → Apple's Metal Shader Converter,
a desktop-only library; its **SPIR-V → SPIRV-Cross → MSL** path is the one that works on iOS, and it is the
one ported here — using the SDK's own SPIR-V translator, which the Vulkan path already exercises daily.

The port adapts it to the SDK: `rex::graphics` namespaces and file layout, the SDK's base classes (which have
moved on from Canary in places), its logging and cvars, its plugin ABI, and the iOS changes made for this game
(shared memory segments, EDRAM extent estimation, render pass area clamping, async pipeline creation without
placeholders, the pipeline storage fixes, presentation features).

## Phases (each ends working, on Mac and iOS, before the next starts)

0. **Scaffold** — backend `metal` in the `rexgpu-xenos` plugin (selected with `--gpu_backend=metal`), a Metal
   provider and presenter in the runtime's UI layer, CAMetalLayer from the SDL window, a cleared frame on screen.
1. **Command processor and shared memory** — guest memory as a Metal buffer (split for devices whose
   `maxBufferLength` is under 512 MB), PM4 through the shared base class, swap presenting the guest frontbuffer.
2. **Shaders and pipelines** — SPIR-V → MSL (SPIRV-Cross, options tuned for Apple GPUs), MTLLibrary and render
   pipeline creation on worker threads, the pipeline storage format shared with Vulkan, Metal binary archives
   so compiled pipelines survive launches.
3. **Render targets / EDRAM** — host render targets as Metal textures, EDRAM buffer, ownership transfers, dumps,
   resolves; render pass load/store actions chosen per pass (the TBDR win MoltenVK can't make for us).
4. **Textures** — untiling and format conversion kernels, samplers, resolve-written textures.
5. **Presentation parity** — MetalFX spatial, picture modes, native widescreen (output width crop, guest aspect),
   upscale cap, frame observer and presented-frame counter, display-link vblank, 2 drawables.
6. **Metal 4** — MTL4CommandQueue/allocators, argument tables, residency sets, the Metal 4 compiler with
   pipeline archives; Metal 3 kept as the fallback for devices and OS versions without it.
7. **EDRAM in tile memory** — research: keeping EDRAM ownership transfers inside a render pass with tile
   shaders / programmable blending instead of copies through memory.

## Validation

- Every phase: the benchmark route (title → hub → level 1 → pause), screenshots compared with the Vulkan path,
  `RL_GPU_STATS` counters, Metal System Trace GPU time, no Metal validation errors (simulator runs with
  validation on).
- Device: the [perf] log (shown vs game fps, frame times, thermal state) against the Vulkan path's numbers.
- The Vulkan path stays the default for shipped test builds until Metal is at least as good on every screen.

## Status (2026-10-24)

Phases 1–5 run end to end on Mac and iOS (`--gpu_backend=metal`; iOS Settings → Display → Renderer, default
Metal from 0.16): title, hub and levels render correctly with Metal API validation clean.

- Render target cache: host render targets, the Vulkan backend's transfer / dump shader generators (SPIR-V →
  MSL), rectangle clears as draws, render pass areas clamped to the rows used (transfers and draws).
- Pipelines: guest shaders through the SPIR-V translator → MSL per render target output set, created on worker
  threads (draws skipped while compiling). `NoContraction` is stripped before SPIRV-Cross: it otherwise becomes an
  `[[clang::optnone]]` call per multiply / add (2–3× the GPU time).
- Textures: the Vulkan load shaders + blits, swizzled texture views, BC decompressed where unsupported.
- Guest memory is used in place (no-copy buffer), at most 2 frames in flight.
- Measured on the M3 Air, same thermal state, level 1: CPU −24% vs MoltenVK, total GPU time ~4% lower.
- Tools: `RL_GPU_LABELS=1` labels encoders for traces (`tools/gpu_labels.py`), `RL_DUMP_MSL=<dir>` dumps MSL.

Metal 4 (0.18): `graphics/metal/encoders.{h,cpp}` wraps every encoder call (Metal 3 names), so one code path
records on either API. On Metal 4 (device family Metal4 + OS, cvar `metal4`, default on; iOS Renderer setting
"Metal 4 / Metal 3 / Vulkan"): an MTL4CommandQueue with a reused MTL4CommandBuffer and an allocator per
submission in flight, completion through a MTLSharedEvent timeline, argument tables (vertex, fragment, compute)
bound by GPU address / resource ID, setBytes through the upload ring, blits inside compute encoders. Hazards are
explicit: each encoder starts with a queue barrier, commands in a compute encoder are serialized with encoder
barriers. Every buffer and texture is in one residency set from creation; `ReleaseResident` / `ReleaseAfterUse`
defer removal and release until the current submission completes (Metal 4 command buffers don't retain). The
presenter stays on its Metal 3 queue: the swap waits for the present event (paintings committed so far) and the
paint waits for the backend's event at the swap's submission (`MetalProvider` Begin/CommitGuestOutputReader).
Falls back to Metal 3 where unsupported (iOS Simulator).

Measured on the M3 Air, level 1 benchmark, either order: Metal 4 ~59 fps (~11–14 ms GPU per frame), Metal 3
~41 fps (~23 ms). Metal API validation clean on Metal 4.

Next: binary archives for pipelines (first-visit compile hitches), fewer serializing barriers (independent
texture loads / resolves in parallel), texture loads straight into textures, merging transfers into passes.

## 0.20

- Metal only on Apple platforms: `REXGLUE_USE_VULKAN` defaults to OFF there (no MoltenVK, no Vulkan loader); the
  Metal backend builds glslang (SPIR-V) and fetches SPIRV-Cross itself (the revision MoltenVK used, namespace
  `MVK_spirv_cross`). `gpu_backend=any` picks Metal. The SDK's Vulkan sources are as upstream.
- Ownership transfers into the attachments of the next draws run in those draws' render pass when the destination
  is an attachment as it is and no transfer reads one (`PerformTransfersAndResolveClears(..., draw_targets)`):
  ~6 fewer render passes a frame in level 1 (no store and reload in between); GPU time about the same on an M3.
- Where the GPU time goes (level 1, Metal 4, M3): ownership transfers ~5 ms a frame, the game's draws ~4 ms,
  texture loads, EDRAM dumps and resolves the rest. The game's own effects are cheap; skipping any of them saves
  nothing measurable. Fewer transfers would need EDRAM emulated in shaders (raster order groups).
- `rex/graphics/frame_stats.h` (RL_GPU_STATS) moved out of the Vulkan folder.

## 0.21

- `gpu_frame_skip` (Low power on iOS): every other frame's draws and resolves are skipped and that frame isn't
  presented; draws that memexport still run. The guest keeps its 60 Hz vblank, so the game runs at full speed with
  a 30 fps picture. Level 1 on the M3: GPU time halved (fragment 2.64 s → 1.26 s per 4.5 s), process CPU time
  -17%. A 15 Pro Max reached "serious" in about 10 minutes at 60 fps with the earlier Low power.

## 0.22

- Low power is back to 60 fps (720p, no MetalFX, the screen's shape). `gpu_frame_skip` is now the overheat
  safety net (iOS settings: Overheat protection, on by default): on at a critical thermal state, or at serious with
  the game under 50 fps for 8 s; off below serious, or after 60 s to try 60 again. RL_FAKE_THERMAL tests it.
- The 15 Pro Max tester held a locked 60 fps for 15 minutes on default settings, reaching "serious" at ~9.5 min.
- The game renders at 720p at the least (its post-effects need 720 rows); lower isn't possible.
