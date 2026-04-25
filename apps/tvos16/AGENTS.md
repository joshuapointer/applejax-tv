# AGENTS.md

## Project Overview

**AppleJax** (`projectm-tv`) — a personal-use Apple TV (tvOS 26) music visualizer built on libprojectM. Swift 5 / SwiftUI app using Metal for presentation and OpenGL ES 3.0 (off-screen) for projectM rendering. Milkdrop presets at 4K 60fps. Not published; personal use only.

Bundle ID: `com.joshpointer.applejax`

## Architecture

```
projectm-tv/
├── App/               # SwiftUI app entry point, AppState (ObservableObject)
├── Audio/             # AudioSource protocol, AudioController, PCMRingBuffer, MusicKit + procedural sources
├── Input/             # Siri Remote → InputCommand → handler
├── Presets/           # PresetLibrary (file-based .milk preset management)
├── Util/              # BPMEstimator
├── Views/             # SwiftUI views (RootView, OverlayView, PresetBrowser, SourcePicker, MusicBrowser)
├── Visualizer/        # GL→Metal rendering pipeline
│   ├── ProjectMBridge.{h,m}        # ObjC bridging header + GL load_proc via dlsym
│   ├── ProjectMRenderer.swift      # Swift wrapper around projectM C API (off-screen GL render)
│   ├── GLMetalBridge.swift         # CVPixelBuffer zero-copy GL↔Metal texture interop
│   ├── MetalRenderer.swift         # Metal presentation pipeline (blit to MTKView)
│   ├── VisualizerViewController.swift  # MTKViewDelegate, orchestrates GL→Metal pipeline
│   └── Shaders/Blit.metal         # Fullscreen triangle blit shader
├── Assets.xcassets/
└── Info.plist
```

### Rendering Pipeline (per frame)

```
MTKView.draw(in:) fires at 60Hz
  ├─ 1. EAGLContext.setCurrent(glContext)
  ├─ 2. GLMetalBridge.nextFramebuffer() → (fbo, CVPixelBuffer)
  ├─ 3. PCMRingBuffer.read() → projectm_pcm_add_float
  ├─ 4. ProjectMRenderer.renderFrame(fbo:)  ← GL renders to CVPixelBuffer
  ├─ 5. glFlush()                            ← submit GL, don't wait
  ├─ 6. GLMetalBridge.metalTexture(from:)   ← zero-copy MTLTexture
  └─ 7. MetalRenderer.render(texture, view) ← Metal blit to drawable
```

### Key data flow

1. **Audio in**: `AudioSource` → `PCMRingBuffer` (lock-free ring buffer, 8192 frames)
2. **PCM drain**: `VisualizerViewController.draw(in:)` drains ring buffer → `projectm_pcm_add_float`
3. **GL render**: projectM renders preset into off-screen FBO (CVPixelBuffer-backed via CVOpenGLESTextureCache)
4. **Zero-copy bridge**: Same CVPixelBuffer read as MTLTexture via CVMetalTextureCache (no GPU copy on A15 unified memory)
5. **Metal present**: Fullscreen triangle blit shader samples GL output texture → MTKView drawable
6. **Navigation**: `AppState.phase` drives `RootView` (picker → musicBrowser → visualizing)

### Component Responsibilities

| Component | Owns | Role |
|---|---|---|
| **GLMetalBridge** | EAGLContext, CVPixelBufferPool (3x), GL FBOs, both texture caches | Texture interop + buffer management |
| **ProjectMRenderer** | projectM handle (OpaquePointer) | projectM C API wrapper, off-screen GL render |
| **MetalRenderer** | MTLCommandQueue, MTLRenderPipelineState, MTLSamplerState | Metal presentation |
| **VisualizerViewController** | MTKView, references to above three | Orchestration, lifecycle, input |

### C interop

- **Bridging header**: `projectm-tv/Visualizer/ProjectMBridge.h` — imports projectM C API + defines `projectm_tv_gl_load_proc`
- **ObjC implementation**: `ProjectMBridge.m` — `dlsym(RTLD_DEFAULT, name)` with fallback to explicit `OpenGLES.framework` handle
- **Static library**: `Frameworks/libprojectM.xcframework` (device arm64 + simulator arm64)

## Build & Run

### Prerequisites
- macOS 12.7+, Xcode 16+ (tvOS 26 SDK), CMake 3.26+
- Apple Developer account for device deployment

### Build libprojectM XCFramework
```bash
# From the parent projectm repo root:
./apps/tvos/scripts/build-libprojectm-xcframework.sh
# Clean rebuild:
./apps/tvos/scripts/build-libprojectm-xcframework.sh --clean
```

### Sync presets
```bash
./apps/tvos/scripts/sync-preset-pack.sh
```
Presets directory is gitignored — run before Archive.

### Xcode project
Generated via XcodeGen from `project.yml`. Open `projectm-tv.xcodeproj` in Xcode. Simulator code-signing is disabled (`CODE_SIGNING_ALLOWED[sdk=appletvsimulator*]: NO`).

## Conventions

- **Language**: Swift 5, tvOS 26 deployment target
- **UI framework**: SwiftUI for navigation/overlays, MTKView (UIKit) for Metal rendering surface
- **State**: Single `AppState` ObservableObject passed via `.environmentObject`
- **Logging**: Custom `Logger` in `App/Logger.swift` — use domain-specific loggers (`logger`, `renderLogger`, `audioLogger`)
- **Audio sources**: Conform to `AudioSource` protocol (start/pause/stop/nowPlaying/isPlaying)
- **Input**: All Siri Remote presses go through `RemoteInputHandler` → `InputCommand` enum → `VisualizerViewController.handleCommand`
- **Preset management**: `PresetLibrary` scans `Resources/presets/` for `.milk` files, supports next/previous/shuffle/jumpTo
- **ObjC bridge**: Keep the bridging header minimal — only projectM C API imports and the GL load_proc declaration

## Gotchas

- **libprojectM is GL-only** — no Metal backend. The GL→Metal bridge (CVPixelBuffer + dual texture cache) is required. Don't try to call projectM with Metal.
- **EAGLContext must be current** before any projectM call. `draw(in:)` calls `EAGLContext.setCurrent(bridge.glContext)` at the start of every frame.
- **Use `_fbo` render variant** — always use `projectm_opengl_render_frame_fbo` with the FBO ID from GLMetalBridge, never `projectm_opengl_render_frame`.
- **CVMetalTexture lifetime** — the `CVMetalTexture` wrapper must outlive the `MTLTexture` it vends. `GLMetalBridge.currentCVMetalTexture` retains it through the render pass.
- **glFlush, not glFinish** — `glFlush` after GL render allows async GPU work. Only use `glFinish` on background entry.
- **Triple buffering** — 3 CVPixelBuffers at 4K = ~95 MB. GL writes buffer N, Metal reads buffer N-2. Don't change buffer count without recalculating memory.
- **No system audio tap on tvOS** — third-party apps cannot capture AirPlay/system audio. Apple Music mode uses MusicKit metadata; local mode uses `ProceduralPCMGenerator` for synthetic beats.
- **PCM drain buffer** is manually allocated/deallocated (`UnsafeMutablePointer<Float>`). Deallocated in `viewWillDisappear`.
- **libprojectM is LGPL-2.1** — linked statically for personal use only. Not for distribution without LGPL compliance.
- **`Resources/presets/` is gitignored** — populated by `scripts/sync-preset-pack.sh` from `~/Music/projectm-presets/`.

## Dependencies

| Dependency | Type | Notes |
|---|---|---|
| libprojectM 4.1.0 | Static XCFramework | Built from parent repo with tvOS patches |
| Metal.framework | System SDK | GPU compute and rendering |
| MetalKit.framework | System SDK | MTKView presentation surface |
| OpenGLES.framework | System SDK | ES 3.0 (off-screen, for projectM) |
| CoreVideo.framework | System SDK | CVPixelBuffer, texture caches |
| AVFoundation.framework | System SDK | Audio engine |
| GameController.framework | System SDK | Siri Remote input |
| MusicKit.framework | System SDK | Apple Music integration |
| CoreMedia.framework | System SDK | Media timing |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/build-libprojectm-xcframework.sh` | Cross-compile libprojectM for tvOS device + simulator, package as XCFramework |
| `scripts/sync-preset-pack.sh` | Copy preset pack from `~/Music/projectm-presets/` into `Resources/presets/` |
| `scripts/toolchains/tvos.cmake` | CMake toolchain for tvOS cross-compilation |
| `ci_scripts/ci_pre_xcodebuild.sh` | Xcode Cloud pre-build hook |
