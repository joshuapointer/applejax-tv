# projectm-tv

Personal-use Apple TV (tvOS) visualizer built on projectM.

**Status:** paper M1 complete — libprojectM tvOS toolchain + upstream patches + build scripts. Xcode project and Swift app skeleton (M2-M10) not yet scaffolded.

## Prerequisites

- macOS 12.7+ (macOS 13+ recommended for tvOS 17 SDK)
- **Xcode 14.2+** (tvOS 16 SDK minimum) or Xcode 15+ (tvOS 17 SDK)
- CMake 3.26+ (`brew install cmake`)
- Apple Developer Program account for TestFlight distribution

> **Note on host architecture:** Apple Silicon is not required. Intel Macs build tvOS apps fine. The simulator slice differs by host (arm64 on Apple Silicon, x86_64 on Intel); `scripts/toolchains/tvos.cmake` picks the correct arch automatically. Device slice is always arm64.

## Step 1 — Build libprojectM for tvOS

This is the M1 hard-gate. If this fails, everything else is blocked.

```bash
cd /path/to/projectm
./apps/tvos/scripts/build-libprojectm-xcframework.sh
```

Expected output: `apps/tvos/Frameworks/libprojectM.xcframework/` containing `tvos-arm64/` and `tvos-arm64-simulator/` (or `tvos-x86_64-simulator/` on Intel hosts).

Verify with:

```bash
plutil -p apps/tvos/Frameworks/libprojectM.xcframework/Info.plist | grep -E 'SupportedPlatform|LibraryPath'
```

Clean rebuild: `./apps/tvos/scripts/build-libprojectm-xcframework.sh --clean`

## Step 2 — Sync the preset pack

The "cream of the crop" Milkdrop preset pack lives at `~/Music/projectm-presets/`. If you don't have it:

```bash
git clone https://github.com/projectM-visualizer/presets-cream-of-the-crop ~/Music/projectm-presets
```

Then sync into `apps/tvos/Resources/presets/`:

```bash
./apps/tvos/scripts/sync-preset-pack.sh
```

Run this before every `Archive` (the sync'd directory is gitignored).

## Upstream patches applied (M1)

Three guarded additive patches to the library let it build cleanly for tvOS. All are behind `#if defined(PROJECTM_TVOS) || defined(PROJECTM_IOS)` so desktop builds are unaffected.

| File | What changed | Why |
|---|---|---|
| `src/libprojectM/Renderer/Platform/GladLoader.cpp` | GLES floor relaxed from 3.2/GLSL 3.20 to 3.0/3.00 on tvOS/iOS | Apple EAGL caps at GLES 3.0; never shipped 3.1 or 3.2 |
| `src/libprojectM/Renderer/Platform/PlatformLibraryNames.hpp` | Apple branch uses `OpenGLES.framework/OpenGLES` on tvOS/iOS instead of `OpenGL.framework/OpenGL` | tvOS has no `OpenGL.framework` |
| `src/libprojectM/Renderer/Platform/GLResolver.cpp` | `ProbeCurrentContext` accepts user-resolver presence as proof of a current EAGL context (reuses the CGL slot) | EAGL has no dlsym-resolvable `CurrentContext` function; the user contract is that they `setCurrent(ctx)` before calling `projectm_create_with_opengl_load_proc` |

Rationale is fully documented in `/Users/joshpointer/Developer/projectm/.omc/autopilot/m1-loader-decision.md`.

## Directory layout (current)

```
apps/tvos/
├── README.md
├── .gitignore
├── Resources/
│   └── presets/                # gitignored; populated by sync-preset-pack.sh
└── scripts/
    ├── build-libprojectm-xcframework.sh
    ├── sync-preset-pack.sh
    └── toolchains/
        └── tvos.cmake
```

M3+ will add the Xcode project, Swift sources, and resources.

## Known limitations (v1 design)

- **No real AirPlay audio visualization** — tvOS third-party apps cannot tap system audio. Workaround: visualize synthetic beat-grid PCM driven by track metadata for Apple Music playback; full PCM tap works only for local-file playback.
- **No screensaver mode** — tvOS blocks third-party screensavers. Full app only.
- **No `UIDocumentPickerViewController` on tvOS** — v1 ships a bundled sample track for the Local File mode. Custom-file browsing deferred to v1.1.
- **GLES + GLKit are deprecated on tvOS** — still functional on tvOS 17/18. Metal port is v2.

## Troubleshooting

### Build fails with "GLES version too low"

The GladLoader patch should have relaxed this. Check that `PROJECTM_TVOS=1` is set in the compile definitions (look for it in the CMake configure log). The toolchain file adds it via `add_compile_definitions`.

### Build fails with "CGLGetCurrentContext missing"

The PlatformLibraryNames patch should have routed the library lookup to `OpenGLES.framework`. Check that `kNativeGlNames` resolves to the OpenGLES framework path on tvOS. Use `cmake --verbose` to see the exact command line.

### `projectm_create_with_opengl_load_proc` returns NULL

The GLResolver patch should have handled this. Ensure your tvOS app calls `EAGLContext.setCurrent(ctx)` **before** calling `projectm_create_*`. The patch treats user-resolver presence as sufficient proof of a current context, but your context must actually be current or the first real GL call will crash.

### Other issues

Review the decision doc: `/Users/joshpointer/Developer/projectm/.omc/autopilot/m1-loader-decision.md`.

## Next steps (M2–M10)

See `/Users/joshpointer/Developer/projectm/.omc/plans/autopilot-impl.md` — 58-task plan. After M1 passes, next batch is M3 (Xcode project scaffolding via XcodeGen).

## License

- libprojectM: LGPL-2.1 (see repo root `COPYING`)
- Preset pack: public-domain-assumed opt-out (see `~/Music/projectm-presets/LICENSE.md`)
- This app: personal-use only, not published
