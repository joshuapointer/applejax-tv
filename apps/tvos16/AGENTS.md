# AGENTS.md

## Project Overview

**AppleJax** (`projectm-tv`) — a personal-use Apple TV (tvOS 16+) music visualizer built on libprojectM. Swift 5 / SwiftUI app using GLKit + OpenGL ES 3.0 for rendering Milkdrop presets. Not published; personal use only.

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
├── Visualizer/        # GL pipeline: EAGLContext → ProjectMBridge (ObjC) → ProjectMRenderer (Swift) → VisualizerViewController (GLKView)
│   ├── ProjectMBridge.{h,m}        # ObjC bridging header + GL load_proc via dlsym
│   ├── ProjectMRenderer.swift      # Swift wrapper around projectM C API
│   ├── VisualizerViewController.swift  # GLKViewDelegate, display link, PCM drain loop
│   ├── DisplayLinkDriver.swift     # CADisplayLink wrapper
│   └── EAGLContextFactory.swift    # EAGL context creation
├── Assets.xcassets/
└── Info.plist
```

### Key data flow

1. **Audio in**: `AudioSource` → `PCMRingBuffer` (lock-free ring buffer, 8192 frames)
2. **PCM drain**: `VisualizerViewController.tick()` drains ring buffer → `projectm_pcm_add_float`
3. **Render**: `GLKView` triggers `glkView(_:drawIn:)` → `projectm_opengl_render_frame_fbo` with GLKView's FBO
4. **Navigation**: `AppState.phase` drives `RootView` (picker → musicBrowser → visualizing)

### C interop

- **Bridging header**: `projectm-tv/Visualizer/ProjectMBridge.h` — imports projectM C API + defines `projectm_tv_gl_load_proc`
- **ObjC implementation**: `ProjectMBridge.m` — `dlsym(RTLD_DEFAULT, name)` with fallback to explicit `OpenGLES.framework` handle
- **Static library**: `Frameworks/libprojectM.xcframework` (device arm64 + simulator arm64)

## Build & Run

### Prerequisites
- macOS 12.7+, Xcode 14.2+ (tvOS 16 SDK), CMake 3.26+
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

- **Language**: Swift 5, tvOS 16 deployment target
- **UI framework**: SwiftUI for navigation/overlays, GLKView (UIKit) for the GL rendering surface
- **State**: Single `AppState` ObservableObject passed via `.environmentObject`
- **Logging**: Custom `Logger` in `App/Logger.swift` — use domain-specific loggers (`logger`, `renderLogger`, `audioLogger`)
- **Audio sources**: Conform to `AudioSource` protocol (start/pause/stop/nowPlaying/isPlaying)
- **Input**: All Siri Remote presses go through `RemoteInputHandler` → `InputCommand` enum → `VisualizerViewController.handleCommand`
- **Preset management**: `PresetLibrary` scans `Resources/presets/` for `.milk` files, supports next/previous/shuffle/jumpTo
- **ObjC bridge**: Keep the bridging header minimal — only projectM C API imports and the GL load_proc declaration

## Gotchas

- **No system audio tap on tvOS** — third-party apps cannot capture AirPlay/system audio. Apple Music mode uses MusicKit metadata; local mode uses `ProceduralPCMGenerator` for synthetic beats.
- **GLKit is deprecated** — still functional on tvOS 16-18. Metal port is future (v2).
- **EAGLContext must be current** before any projectM call. `VisualizerViewController.setupGL()` calls `EAGLContext.setCurrent(context)` before `projectm_create_with_opengl_load_proc`.
- **Use `_fbo` render variant** — GLKView owns the framebuffer; always use `projectm_opengl_render_frame_fbo` with `GL_FRAMEBUFFER_BINDING`, never `projectm_opengl_render_frame`.
- **PCM drain buffer** is manually allocated/deallocated (`UnsafeMutablePointer<Float>`). Deallocated in `viewWillDisappear`.
- **libprojectM is LGPL-2.1** — linked statically for personal use only. Not for distribution without LGPL compliance.
- **`Resources/presets/` is gitignored** — populated by `scripts/sync-preset-pack.sh` from `~/Music/projectm-presets/`.

## Dependencies

| Dependency | Type | Notes |
|---|---|---|
| libprojectM 4.1.0 | Static XCFramework | Built from parent repo with tvOS patches |
| OpenGLES.framework | System SDK | ES 3.0 |
| GLKit.framework | System SDK | Deprecated but functional |
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
