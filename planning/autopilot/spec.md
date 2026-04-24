# projectM tvOS Visualizer — Technical Specification (v1)

Phase 0 / Architect deliverable. Implementation plan for the Apple TV visualizer described in `requirements.md`. Scope: TestFlight-only personal build; bundle ID `com.joshpointer.projectm-tv`; tvOS 17.0 minimum.

All upstream questions (Q1–Q12) are resolved in the prompt and referenced here without re-litigation. The content below is prescriptive: file paths, CMake targets, Swift types, and function-level contracts.

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Apple TV (tvOS 17+)                              │
│                                                                           │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Xcode tvOS App — projectm-tv.app                                 │  │
│  │                                                                     │  │
│  │  SwiftUI layer                                                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                │  │
│  │  │ RootView    │  │ OverlayView │  │ SourcePicker│   AppState     │  │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘   (@Observable) │  │
│  │         │                │                │                         │  │
│  │  ┌──────┴────────────────┴────────────────┴──────────────────────┐ │  │
│  │  │ VisualizerViewController (UIViewController + GLKViewDelegate) │ │  │
│  │  │    - owns EAGLContext (GLES 3.0)                              │ │  │
│  │  │    - hosts GLKView (CAEAGLLayer)                              │ │  │
│  │  │    - runs CADisplayLink @ 60 Hz                               │ │  │
│  │  └──┬────────────┬──────────────┬─────────────┬──────────────────┘ │  │
│  │     │            │              │             │                     │  │
│  │  ┌──▼───────┐ ┌──▼────────┐ ┌──▼──────┐ ┌───▼────────────────┐   │  │
│  │  │ProjectM  │ │PresetLib  │ │Remote   │ │AudioController      │   │  │
│  │  │Renderer  │ │(enumerate,│ │Input    │ │(routes to one of:)  │   │  │
│  │  │(Swift    │ │ shuffle)  │ │Handler  │ ├─────────────────────┤   │  │
│  │  │ wrapper  │ │           │ │         │ │ AudioEngineSource   │   │  │
│  │  │ of C API)│ │           │ │         │ │ (AVAudioEngine tap) │   │  │
│  │  └────┬─────┘ └────┬──────┘ └─────────┘ ├─────────────────────┤   │  │
│  │       │            │                     │ MusicKitSource      │   │  │
│  │       │            │                     │ (ApplicationMusic   │   │  │
│  │       │            │                     │  Player + procedural│   │  │
│  │       │            │                     │  PCM generator)     │   │  │
│  │       │            │                     └──────────┬──────────┘   │  │
│  │       │            │                                │               │  │
│  │       │            │            ┌───────────────────┘               │  │
│  │       │            │            │ float[] PCM                        │  │
│  │       │            │            ▼                                    │  │
│  │       │            │      PCMRingBuffer  (lock-free SPSC,            │  │
│  │       │            │                      N >= 4 * max_samples)      │  │
│  │       │            │            │                                    │  │
│  │       │            │            │ (drained on display-link tick)     │  │
│  │       ▼            ▼            ▼                                    │  │
│  │  ┌─────────────────────────────────────────────────────────────┐   │  │
│  │  │ libprojectM.xcframework  (C API, static, GLES 3.0 rendering) │   │  │
│  │  │   projectm_create_with_opengl_load_proc(…)                   │   │  │
│  │  │   projectm_pcm_add_float / projectm_opengl_render_frame      │   │  │
│  │  │   projectm_load_preset_file / projectm_set_preset_locked     │   │  │
│  │  └─────────────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│         │ dlsym via custom load_proc                                      │
│         ▼                                                                  │
│  /System/Library/Frameworks/OpenGLES.framework  (device + simulator)      │
│  /System/Library/Frameworks/MusicKit.framework                            │
│  /System/Library/Frameworks/AVFoundation.framework                        │
│  /System/Library/Frameworks/GameController.framework                      │
└─────────────────────────────────────────────────────────────────────────┘
```

Key data flows:

- **Render thread (main, driven by CADisplayLink):** every frame → drain `PCMRingBuffer` → `projectm_pcm_add_float` → `projectm_opengl_render_frame` → GLKView presents.
- **Audio thread (AVAudioEngine tap on `mainMixerNode`):** for `AudioEngineSource` only; callback writes interleaved float32 LRLRLR into `PCMRingBuffer`. Never allocates, never locks.
- **Procedural audio thread (`DispatchQueue` at real-time QoS):** for `MusicKitSource`; generates bandlimited noise bursts aligned to a beat grid derived from MusicKit metadata, writes to `PCMRingBuffer` on the same contract as the tap.
- **Main thread control:** MusicKit authorization, preset switch on remote swipe, overlay show/hide, app lifecycle.

Hard v1 limitation — **cannot tap Apple Music DRM audio**. `ApplicationMusicPlayer` plays out-of-process in `mediaserverd`; no in-app tap can observe its PCM. For Apple Music mode the visualizer reacts to a **procedural synthetic PCM** seeded by track metadata (BPM, energy), not the actual audio. This must be stated in the app's About screen and TestFlight "What to Test" notes.

---

## 2. Directory Layout

All new files live under `apps/tvos/`. Nothing above this directory changes **except** the two justified upstream edits in §4.6.

```
apps/tvos/
├── README.md                                # Build instructions, troubleshooting
├── projectm-tv.xcodeproj/                   # Generated once, committed
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/projectm-tv.xcscheme
│
├── projectm-tv/                             # Main app target sources
│   ├── Info.plist
│   ├── projectm_tv.entitlements             # com.apple.developer.musickit
│   ├── Assets.xcassets/
│   │   ├── AppIcon.brandassets/
│   │   ├── TopShelfImage.brandassets/
│   │   └── LaunchImage.imageset/
│   │
│   ├── App/
│   │   ├── ProjectMTVApp.swift              # @main SwiftUI App
│   │   ├── AppState.swift                   # @Observable root state
│   │   ├── AppDelegate.swift                # UIApplicationDelegate shim (lifecycle)
│   │   └── Logger.swift                     # os.Logger wrapper
│   │
│   ├── Views/
│   │   ├── RootView.swift                   # Switches source-picker / visualizer
│   │   ├── SourcePickerView.swift           # First-run modal (F22)
│   │   ├── VisualizerContainerView.swift    # UIViewControllerRepresentable
│   │   ├── OverlayView.swift                # Preset name + now-playing HUD
│   │   └── AcknowledgementsView.swift       # LGPL + preset license
│   │
│   ├── Visualizer/
│   │   ├── VisualizerViewController.swift   # UIViewController + GLKViewDelegate
│   │   ├── ProjectMRenderer.swift           # Swift wrapper over C API
│   │   ├── EAGLContextFactory.swift         # Creates GLES 3.0 context
│   │   ├── DisplayLinkDriver.swift          # CADisplayLink at 60 Hz
│   │   └── ProjectMBridge.h / .m            # Objective-C glue for load_proc
│   │
│   ├── Audio/
│   │   ├── AudioController.swift            # Protocol + router
│   │   ├── AudioEngineSource.swift          # Local-file AVAudioEngine + tap
│   │   ├── MusicKitSource.swift             # Apple Music + procedural driver
│   │   ├── ProceduralPCMGenerator.swift     # Beat-grid noise generator
│   │   └── PCMRingBuffer.swift              # Lock-free SPSC ring
│   │
│   ├── Presets/
│   │   ├── PresetLibrary.swift              # Enumerate bundled tree, shuffle
│   │   └── PresetManifest.swift             # Typed index of categories
│   │
│   ├── Input/
│   │   ├── RemoteInputHandler.swift         # UIPress + GCMicroGamepad
│   │   └── InputCommand.swift               # enum of app-level commands
│   │
│   └── Util/
│       ├── LockFreeSPSC.swift               # std::atomic-backed ring primitives
│       └── BPMEstimator.swift               # Fallback when MusicKit lacks tempo
│
├── projectm-tvTests/                        # XCTest unit tests
│   ├── PCMRingBufferTests.swift
│   ├── PresetLibraryTests.swift
│   ├── ProceduralPCMGeneratorTests.swift
│   └── RemoteInputHandlerTests.swift
│
├── projectm-tvUITests/                      # Optional; smoke launch test only
│   └── LaunchTests.swift
│
├── Frameworks/
│   └── libprojectM.xcframework/             # Produced by scripts/build-libprojectm-xcframework.sh
│       ├── Info.plist
│       ├── tvos-arm64/
│       │   ├── libprojectM.a
│       │   └── Headers/projectM-4/…
│       └── tvos-arm64-simulator/
│           ├── libprojectM.a
│           └── Headers/projectM-4/…
│
├── Resources/
│   ├── presets/                             # Mirror of ~/Music/projectm-presets/
│   │   ├── LICENSE.md                       # copied verbatim
│   │   ├── README.md
│   │   ├── ! Transition/…
│   │   ├── Dancer/…
│   │   ├── Drawing/…
│   │   ├── Fractal/…
│   │   ├── Geometric/…
│   │   ├── Hypnotic/…
│   │   ├── Particles/…
│   │   ├── Reaction/…
│   │   ├── Sparkle/…
│   │   ├── Supernova/…
│   │   └── Waveform/…
│   ├── Licenses/
│   │   ├── LGPL-2.1.txt                     # copied from /COPYING
│   │   └── projectM-attribution.md          # NFR N9 / AC13
│   └── Fonts/                               # (reserved; v1 uses system SF Pro)
│
└── scripts/
    ├── build-libprojectm-xcframework.sh     # Configures + builds CMake
    ├── sync-preset-pack.sh                  # Copies ~/Music/projectm-presets → Resources/presets
    └── toolchains/
        └── tvos.cmake                       # CMake toolchain file (see §4.1)
```

Notes on naming:
- Swift file names are Swift-style (upper camel). Module name: `projectm_tv`.
- The XCFramework is the **only** build artifact imported from CMake; Xcode never reads the CMake cache.
- `Resources/presets/` is produced by `sync-preset-pack.sh` (rsync) and is **gitignored** except for a placeholder `.gitkeep` plus `LICENSE.md`. Developer runs the sync once before `Archive`.

---

## 3. Components & Responsibilities

### 3.1 `ProjectMRenderer` — `Visualizer/ProjectMRenderer.swift`

- Owns the `projectm_handle`.
- Constructor takes a `load_proc` closure (used by `projectm_create_with_opengl_load_proc`) and a `CGSize` for initial viewport.
- Exposes:
  - `func loadPreset(at url: URL, smooth: Bool)`
  - `func setLocked(_ locked: Bool)`
  - `func setViewport(size: CGSize, scale: CGFloat)`
  - `func addPCM(_ samples: UnsafePointer<Float>, frameCount: Int, channels: Int32)`
  - `func renderFrame(intoFBO fbo: GLuint)` — calls `projectm_opengl_render_frame_fbo` for determinism with `GLKView`'s default FBO.
- Thread model: only the render thread (main) calls into it. The PCM path is indirect: the ring buffer is the thread-safe surface, and `addPCM` is called on the render thread after draining.

### 3.2 `AudioController` — `Audio/AudioController.swift`

Protocol `AudioSource` with two implementations. `AudioController` owns the active source and the single shared `PCMRingBuffer`.

```swift
protocol AudioSource: AnyObject {
    func start() throws
    func pause()
    func stop()
    var nowPlaying: NowPlayingInfo? { get }
    var isPlayingPublisher: AnyPublisher<Bool, Never> { get }
}
```

### 3.3 `AudioEngineSource` — `Audio/AudioEngineSource.swift`

- For local files (F6/F7).
- Builds `AVAudioEngine` graph: `AVAudioPlayerNode` → `AVAudioEnvironmentNode` (identity) → `mainMixerNode` → `outputNode`.
- Installs tap on `mainMixerNode` at the mixer's output format (typically 48 kHz, 2 ch float32 non-interleaved).
- Tap callback: converts to interleaved LRLRLR, writes to `PCMRingBuffer`. **No allocations, no Swift locks** (uses `UnsafeMutableBufferPointer` and `OSAtomic`-equivalent C atomics via `LockFreeSPSC`).
- End-of-track: if a folder was picked, advance to next file alphabetically (wrap); if a single file, loop (Q12).

### 3.4 `MusicKitSource` — `Audio/MusicKitSource.swift`

- Uses `MusicKit.ApplicationMusicPlayer.shared`.
- Subscribes to `state.$playbackStatus` and `queue.$currentEntry` via Combine.
- On `currentEntry` change, extracts BPM:
  - First try `Song.tempo` if the resolved entry is a `Song`.
  - Else default to 120 BPM.
- Starts `ProceduralPCMGenerator` with `(bpm, isPlaying)` — generator writes to the **same** `PCMRingBuffer` the render thread drains.
- Handles authorization via `MusicAuthorization.request()`; surfaces state to `AppState` so `SourcePickerView` can disable Apple Music mode if denied (F26).

### 3.5 `ProceduralPCMGenerator` — `Audio/ProceduralPCMGenerator.swift`

- Real-time thread (`DispatchQueue(label: "pm.procaudio", qos: .userInteractive)` with a timer loop or `CFRunLoop`).
- Produces ~48 kHz stereo float output in 1024-frame chunks.
- Signal model:
  - **Carrier:** low-volume pink noise (−24 dBFS).
  - **Beat pulses:** on each beat (at `60.0 / bpm` second intervals), inject a 50 ms amplitude burst shaped by an exponential envelope (attack 5 ms, decay 45 ms) at −6 dBFS.
  - **Phase:** every 4 beats (bar boundary), introduce a low-frequency modulation on carrier amplitude to give projectM "bass" response.
- When `isPlaying == false`: write silence (projectM's idle mode will render gracefully per Q6).
- Rationale: gives projectM something visually lively that is loosely tied to the track, without pretending to be the real audio.

### 3.6 `PCMRingBuffer` — `Audio/PCMRingBuffer.swift`

- Single-producer / single-consumer, lock-free.
- Capacity: `max(4 * projectm_pcm_get_max_samples(), 8192)` frames stereo → allocate `capacityFrames * 2 * MemoryLayout<Float>.stride` bytes.
  - `projectm_pcm_get_max_samples()` returns 576 frames historically; 4× is 2304 frames; we round up to 8192 for headroom against 4096-frame taps.
- Producer writes interleaved LRLRLR float32.
- Consumer reads up to `projectm_pcm_get_max_samples()` frames per render tick.
- Underflow: consumer sees < min threshold → feeds silence (F8); projectM still renders.
- Overflow: producer drops oldest (advances read head atomically). Logged at `debug` level only.
- Implementation: backed by a `ContiguousArray<Float>` and two `UnsafeAtomic<UInt64>` indices (swift-atomics package or raw `_Atomic`).

### 3.7 `PresetLibrary` — `Presets/PresetLibrary.swift`

- On init, walks `Bundle.main.resourceURL!.appendingPathComponent("presets")` with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`.
- Collects all files ending in `.milk` (and optionally `.prjm`).
- Builds an array of `URL`, shuffles via `SystemRandomNumberGenerator` (Q5).
- Exposes `next()` / `previous()` / `current()` cycling with history (ring of last 64).
- Skips presets that cause `projectm_load_preset_file` to fail (F13); observes failure via the optional projectM preset-switch callback from `callbacks.h` (`projectm_set_preset_switch_failed_event_callback`). Failed URLs are moved to a `failed` set and not reselected.

### 3.8 `RemoteInputHandler` — `Input/RemoteInputHandler.swift`

- Installed as `UIViewController.pressesBegan/pressesEnded` override in `VisualizerViewController`.
- Secondary: monitors `GCController.controllers()` for Siri Remote 2nd-gen (which delivers swipe gestures as `UIPress` plus optional `GCMicroGamepad` input).
- Debounces (F18): coalesces multiple press events within 100 ms into one command.
- Commands emitted via a `@Published var command: InputCommand?` or closure.

Full mapping table in §9.

### 3.9 `OverlayView` — `Views/OverlayView.swift`

- SwiftUI view bound to `AppState.overlay`.
- Layout: bottom-left gutter, ~25% screen height, rounded rectangle with 60% black blur background (`ultraThinMaterial` on tvOS 17).
- Displays: preset name, source label, track metadata (title / artist / album) when available, lock indicator (SF Symbol `lock.fill`).
- Auto-hides after 5 s via a `Task` that cancels on interaction (F20).
- Dimming: `VisualizerViewController` applies a 30% black `UIView` overlay behind the SwiftUI overlay when visible (F21).

### 3.10 `AppState` — `App/AppState.swift`

```swift
@Observable
final class AppState {
    enum Phase { case picker, visualizing }
    var phase: Phase = .picker
    var activeSource: SourceKind = .idle      // idle | appleMusic | localFile
    var isLocked: Bool = false                // does NOT persist (Q10)
    var isOverlayVisible: Bool = false
    var nowPlaying: NowPlayingInfo?
    var currentPresetName: String = "(none)"
    var musicAuthorization: MusicAuthorization.Status = .notDetermined

    // Persisted via UserDefaults (F23):
    @ObservationIgnored var lastSource: SourceKind       // restored on launch
    // NOT persisted: isLocked (Q10), any MusicKit tokens (F25)
}
```

Deployment target is tvOS 17.0; `@Observable` (Observation framework) is available. If the developer later bumps minimum deployment below 17, switch to `ObservableObject` + `@Published`.

---

## 4. Build System Design

### 4.1 CMake Toolchain — `apps/tvos/scripts/toolchains/tvos.cmake`

A dedicated toolchain file drives the CMake configure step. Highlights:

```cmake
set(CMAKE_SYSTEM_NAME      tvOS)                 # CMake 3.26+ native tvOS support
set(CMAKE_SYSTEM_PROCESSOR arm64)
# SDK switched by caller: -DCMAKE_OSX_SYSROOT=appletvos  OR  appletvsimulator
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH NO)
set(CMAKE_XCODE_ATTRIBUTE_SKIP_INSTALL NO)

# Force static, GLES, no shared lib, no SDL, no tests.
set(BUILD_SHARED_LIBS          OFF CACHE BOOL "" FORCE)
set(ENABLE_GLES                ON  CACHE BOOL "" FORCE)
set(ENABLE_PLAYLIST            OFF CACHE BOOL "" FORCE)   # we roll our own in Swift
set(ENABLE_SDL_UI              OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_GLM          OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_PROJECTM_EVAL OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING              OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL             OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Bitcode (Xcode 14+ no longer requires; keep disabled to match Apple defaults).
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)

# Signal the tvOS branch to projectM sources.
add_compile_definitions(PROJECTM_TVOS=1 USE_GLES=1)
```

The toolchain is selected by the build script, not by a new top-level CMake option. This keeps the upstream `CMakeLists.txt` untouched for the common case.

### 4.2 XCFramework Producer — `apps/tvos/scripts/build-libprojectm-xcframework.sh`

Pseudocode (bash):

```bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/apps/tvos/Frameworks"
BUILD="$ROOT/build-tvos"
TOOLCHAIN="$ROOT/apps/tvos/scripts/toolchains/tvos.cmake"

configure_and_build () {
  local sdk="$1"      # appletvos | appletvsimulator
  local build="$BUILD/$sdk"
  cmake -S "$ROOT" -B "$build" \
        -G Xcode \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_BUILD_TYPE=Release
  cmake --build "$build" --config Release --target projectM -- -quiet
}

configure_and_build appletvos
configure_and_build appletvsimulator

rm -rf "$OUT/libprojectM.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/appletvos/src/libprojectM/Release-appletvos/libprojectM-4.a" \
    -headers "$ROOT/src/api/include" \
  -library "$BUILD/appletvsimulator/src/libprojectM/Release-appletvsimulator/libprojectM-4.a" \
    -headers "$ROOT/src/api/include" \
  -output "$OUT/libprojectM.xcframework"
```

The XCFramework contains:
- `tvos-arm64/libprojectM.a` (device)
- `tvos-arm64-simulator/libprojectM.a` (simulator)
- Both with a `Headers/projectM-4/` subtree copied verbatim from `src/api/include/projectM-4/`.

### 4.3 Xcode Consumption

- `projectm-tv.xcodeproj` has a "Frameworks, Libraries, and Embedded Content" entry pointing at `Frameworks/libprojectM.xcframework` with **"Do Not Embed"** (static library — no dylib to embed).
- "Header Search Paths" includes `$(SRCROOT)/Frameworks/libprojectM.xcframework/tvos-arm64/Headers`. Xcode automatically picks the right slice at build time; the path above is canonical, and Xcode's build system resolves the slice correctly because the XCFramework's `Info.plist` advertises each variant.
- Swift bridging header at `projectm-tv/ProjectMBridge.h`:
  ```c
  #include "projectM-4/projectM.h"
  #include "projectM-4/audio.h"
  #include "projectM-4/core.h"
  #include "projectM-4/parameters.h"
  #include "projectM-4/render_opengl.h"
  ```
- Required system frameworks linked in the app target: `OpenGLES.framework`, `MusicKit.framework`, `AVFoundation.framework`, `GameController.framework`, `CoreMedia.framework`, `GLKit.framework`, `UIKit.framework`.

### 4.4 Preset Pack Bundling

- `sync-preset-pack.sh`:
  ```bash
  rsync -a --delete --exclude='.*' \
    ~/Music/projectm-presets/  apps/tvos/Resources/presets/
  ```
- Xcode build phase "Copy Bundle Resources" includes `Resources/presets` as a folder reference (blue, not group). Folder references preserve the directory structure in the `.app`; resource paths at runtime are `Bundle.main.bundleURL / "presets" / …`.
- Pack size is 155 MB, well under the 4 GB TestFlight ceiling (N/A to N9 but worth stating for risk tracking).

### 4.5 GL Function Loading on tvOS

Upstream `Platform/PlatformLibraryNames.hpp` looks for `libGLESv2.dylib` / `libGLESv3.dylib` (see `src/libprojectM/Renderer/Platform/PlatformLibraryNames.hpp:58-65`). **These do not exist on tvOS/iOS** — OpenGL ES is delivered via `OpenGLES.framework`, and core `gl*` symbols are globally exported into the process once the framework is linked. The tvOS app handles this by:

1. Always using `projectm_create_with_opengl_load_proc(&tvos_load_proc, nullptr)` — never `projectm_create()`.
2. `tvos_load_proc` calls `dlsym(RTLD_DEFAULT, name)` (works because `OpenGLES.framework` is linked into the app binary, making the symbols globally visible via the two-level-namespace flat-lookup). Fallback: `dlsym` against an explicit handle to `OpenGLES` via `dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY)`.

This avoids needing the upstream dylib-name table to know about tvOS.

### 4.6 Upstream Edits (Justified)

The goal is **zero upstream edits**. Two places will likely force our hand. Both are small and behind a `PROJECTM_TVOS` guard so desktop behavior is unchanged. Alternatives are listed; the spec's preferred resolution is stated.

**Edit 1 (required): Relax the GLES version floor for tvOS.**

Location: `src/libprojectM/Renderer/Platform/GladLoader.cpp:46-54`.

Current code demands GLES 3.2 / GLSL 3.20. Apple EAGL on tvOS 17/18 tops out at **GLES 3.0 / GLSL 3.00-es** (Apple never shipped 3.1 or 3.2 on EAGL). Proposed change:

```cpp
#ifdef USE_GLES
#  if defined(PROJECTM_TVOS) || defined(PROJECTM_IOS)
    glCheck.WithApi(GLApi::OpenGLES)
           .WithMinimumVersion(3, 0)
           .WithMinimumShaderLanguageVersion(3, 0)
           .WithRequireCoreProfile(false);
#  else
    glCheck.WithApi(GLApi::OpenGLES)
           .WithMinimumVersion(3, 2)
           .WithMinimumShaderLanguageVersion(3, 20)
           .WithRequireCoreProfile(false);
#  endif
#else
…
```

Risk: if any Milkdrop preset shader in `src/libprojectM/MilkdropPreset/` hard-requires GLSL ES 3.20 features (`sample` qualifiers, compute shaders, `textureGatherOffsets`), those presets will fail at compile time. Mitigation: F13 silently skips them; N6 allows 5% skip rate. Architect assessment: projectM's preset shaders are ports of Milkdrop HLSL which is GLSL ES 3.00-es-compatible; GLSL 3.20 features are primarily used in the **renderer's own** shaders, not preset shaders. Those renderer shaders would need to be audited; worst case, a small `#version` shim downgrade is needed. This is a Milestone M1 verification task.

Alternative considered but rejected:
- **Keep 3.2 and use ANGLE-over-Metal as a GLES 3.2 provider.** Rejected — ANGLE is not distributed in tvOS SDK; bundling a 30 MB ANGLE dylib for a personal TestFlight build is disproportionate. Also, the user's constraint (GLES 3.0 / EAGLContext) is explicit.

**Edit 2 (conditional, likely needed): Teach `PlatformLibraryNames.hpp` about tvOS / iOS.**

Location: `src/libprojectM/Renderer/Platform/PlatformLibraryNames.hpp:40-66`.

Currently the macOS/Apple branch names `libGLESv2.dylib` / `libGLESv3.dylib`. Those don't exist on iOS/tvOS. Option A (preferred): use the custom `projectm_load_proc` path (§4.5) and **don't change this file** — but only if the resolver's platform-name probe is bypassed when `user_resolver == yes`. Verification task for M1.

Option B (fallback if Option A fails): add iOS/tvOS branch that points at `OpenGLES.framework`:

```cpp
#elif defined(__APPLE__) && (TARGET_OS_IOS || TARGET_OS_TV)
constexpr std::array<const char*, 2> kNativeGlesNames = {
    "/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
    nullptr};
#elif defined(__APPLE__)
   // existing macOS branch
```

Justification: this is a portable, additive change; no desktop behavior change. Five lines.

**These two edits total ≤20 lines, all guarded. Every other projectM source file is untouched. The top-level `CMakeLists.txt` is untouched.**

---

## 5. Audio Pipeline Design

### 5.1 Thread Model

```
┌─────────────────────┐
│ AVAudioEngine tap   │  (AudioEngineSource only)
│ or RT generator     │  callback / timer at ~21 Hz (1024 @ 48k)
│ thread (realtime)   │
└─────────┬───────────┘
          │ write interleaved float32
          ▼
┌─────────────────────┐
│ PCMRingBuffer       │  SPSC, 8192 frames stereo, ~170 ms @ 48k
│ (lock-free)         │
└─────────┬───────────┘
          │ read up to max_samples per tick
          ▼
┌─────────────────────┐
│ CADisplayLink tick  │  main thread @ 60 Hz
│   drain → pcm_add   │
│   → render_frame    │
└─────────────────────┘
```

### 5.2 Sample Rate Handling

- `AVAudioEngine` `mainMixerNode.outputFormat(forBus: 0)` is queried at start; expected 48 kHz on Apple TV 4K.
- projectM does not care about sample rate (N4 latency budget is dominated by ring buffer occupancy and frame latency, not SR).
- The procedural generator runs fixed at 48 kHz (N4).

### 5.3 Buffer Sizing

- `projectm_pcm_get_max_samples()` → expected 576.
- Ring capacity: `max(4 * 576, 8192) = 8192` frames stereo.
- Per-tick consumer read: `min(available, 576)` frames.
- Per render frame @ 60 Hz, 576 frames @ 48 kHz = 12 ms of audio consumed, but 16.6 ms of wall clock elapses → consumer is under-fed. That's fine; projectM uses whatever it gets, and the ring buffer drains incrementally over multiple frames as audio fills faster than the render ticks consume. **Key property:** the ring's total latency remains bounded around the 4×-max-samples mark (~48 ms) once in steady state.

### 5.4 Channel Handling

- Always call `projectm_pcm_add_float(handle, samples, count, PROJECTM_STEREO)` (F4).
- Sample layout is LRLRLR as documented at `src/api/include/projectM-4/audio.h:50`.
- Mono local files are up-mixed to stereo (duplicate channel) by `AVAudioEngine`'s mainMixerNode before the tap, so no extra logic needed.

### 5.5 Audio Interruptions (N5 / F27)

- Subscribe to `AVAudioSession.interruptionNotification` (still posted on tvOS even though the session model differs from iOS).
- On `.began`: `audioSource.pause()`; ring buffer remains populated; render continues with silence after drain.
- On `.ended`: restart the engine, re-install the tap.
- On `AVAudioEngineConfigurationChange`: tear down and rebuild the `AudioEngineSource` (sample rate may have changed, e.g. HDMI audio reconfiguration).

---

## 6. Rendering Pipeline Design

### 6.1 Surface

- `VisualizerViewController` embeds a `GLKView` as its `view`. `GLKView` wraps a `CAEAGLLayer` internally.
- `EAGLContextFactory` creates an `EAGLContext(api: .openGLES3)`. If that returns `nil`, the app surfaces an unrecoverable error (affects essentially no real device, since A12+ support GLES 3.0).
- `GLKView.drawableColorFormat = .RGBA8888`, `drawableDepthFormat = .format24`, `drawableStencilFormat = .format8`, `drawableMultisample = .none` (projectM handles its own post-processing; MSAA at 4K is too expensive).

### 6.2 Display Link

- `DisplayLinkDriver` wraps `CADisplayLink(target: self, selector: #selector(tick))`.
- `preferredFramesPerSecond = 60` (tvOS 17 `preferredFrameRateRange` could be used for Pro-Motion-style adaptive, but Apple TV is fixed at 60 Hz).
- On tick:
  1. Drain up to `max_samples` frames from `PCMRingBuffer` into a stack buffer (`[Float]` of size `max_samples * 2`).
  2. `ProjectMRenderer.addPCM(...)`.
  3. `glkView.setNeedsDisplay()` → triggers `glkView(_:drawIn:)` → `ProjectMRenderer.renderFrame(intoFBO: defaultFBO)`.

### 6.3 Viewport

- On `viewDidLayoutSubviews` and on `traitCollectionDidChange`:
  - `let scale = view.window?.screen.nativeScale ?? 1.0`
  - `projectm_set_window_size(handle, size_t(view.bounds.width * scale), size_t(view.bounds.height * scale))`
- Apple TV 4K renders at 3840×2160 by default; scale is 2 for 1080p UIs, but for fullscreen GLKView the backing store is native. If perf is insufficient (N1), `contentScaleFactor = 1.0` to drop to 1080p render target is the first mitigation.

### 6.4 Context Loss (N5)

- On `UIApplication.didEnterBackgroundNotification`: stop `CADisplayLink`, flush GL (`glFinish`), pause audio source.
- On `UIApplication.willEnterForegroundNotification`: re-make context current (`EAGLContext.setCurrent(context)`), resume display link; if `projectm_create_*` was previously torn down, re-create it (we retain the instance by default — tvOS rarely purges GL contexts of foreground-recent apps, but we handle it).

---

## 7. MusicKit Integration

### 7.1 Authorization Flow (F26)

- `AppDelegate.application(_:didFinishLaunchingWithOptions:)` does **not** pre-authorize.
- On entering Apple Music mode from `SourcePickerView`, call `MusicAuthorization.request()`.
- If `.authorized`: proceed.
- If `.denied` or `.restricted`: disable Apple Music button in picker, show explanatory text referencing Settings app. Local File mode remains available.

### 7.2 Playback

- `ApplicationMusicPlayer.shared` is the only API used.
- Library browse UI: the minimum viable UI in v1 is a `MusicItemCollectionView`-backed list of the user's library (or their Apple Music recommendations via `MusicPersonalRecommendationsRequest`). This is **the one meaningful UI concession** outside the source picker: we need *some* way to pick a song from inside the app. Architect's proposal for v1: a simple `NavigationStack` with three top-level sections — "Recently Played", "Playlists", "Songs" — each backed by a single MusicKit request.
- On selection: `try await player.queue = ApplicationMusicPlayer.Queue(for: [selection])` then `try await player.play()`.

### 7.3 Metadata Subscription

- `for await state in player.state.values { … }` — reacts to `playbackStatus`.
- `for await entry in player.queue.$currentEntry.values { … }` — reacts to track change.
- When `currentEntry` is a `Song`, attempt `song.tempo` (real property on MusicKit `Song` in iOS/tvOS 16+). Fallback: 120 BPM.

### 7.4 Procedural Audio Driver (Q1/Q2 resolution)

Rationale repeated for the spec's self-containment: `mediaserverd` plays Apple Music DRM content out-of-process. An in-app tap sees nothing. The driver described in §3.5 fills the gap so the visualizer remains lively. The user will see **visualizer reacting to a beat grid, not to the actual audio**, and this limitation is disclosed in `AcknowledgementsView` and TestFlight notes.

---

## 8. Preset Bundling

### 8.1 Build-Time Copy

- `sync-preset-pack.sh` runs rsync from `~/Music/projectm-presets/` into `apps/tvos/Resources/presets/`.
- Developer runs it before every `Archive` (documented in README).
- Xcode "Copy Bundle Resources" includes `Resources/presets` as a **folder reference** (preserves subdirectories).
- Result: `projectm-tv.app/presets/Dancer/…`, `projectm-tv.app/presets/LICENSE.md`, etc.

### 8.2 Runtime Path Resolution

```swift
let presetsRoot = Bundle.main.bundleURL.appendingPathComponent("presets")
// Walk directory tree, collect *.milk files
```

No `$HOME` references; no Documents directory writes (the preset pack is read-only).

### 8.3 License Compliance

- `Resources/presets/LICENSE.md` is always bundled.
- `AcknowledgementsView` displays:
  - LGPL-2.1 attribution for projectM (N9, AC13).
  - Link to projectM source (GitHub URL in-text — not tappable necessarily, but discoverable in TestFlight notes too).
  - Preset pack license text.
- TestFlight "What to Test" notes contain the same attribution per AC13.

---

## 9. Remote Input Mapping

Siri Remote events on tvOS arrive as `UIPress` events on the responder chain (primary) and as `GCMicroGamepad` inputs (secondary, for analog swipe gestures). The table below is the authoritative mapping.

| Source event | Condition | Command | Effect |
|---|---|---|---|
| `UIPress.PressType.leftArrow` (pressed) | always | `.previousPreset` | `PresetLibrary.previous()` → `projectm_load_preset_file(…, smooth: true)` |
| `UIPress.PressType.rightArrow` (pressed) | always | `.nextPreset` | `PresetLibrary.next()` → `projectm_load_preset_file(…, smooth: true)` |
| `UIPress.PressType.select` (pressed) | always | `.toggleLock` | `projectm_set_preset_locked(!current)` + update `AppState.isLocked` |
| `UIPress.PressType.menu` (pressed) | overlay hidden | `.showOverlay` | `AppState.isOverlayVisible = true` |
| `UIPress.PressType.menu` (pressed) | overlay visible | `.hideOverlay` | `AppState.isOverlayVisible = false` |
| `UIPress.PressType.playPause` (pressed) | always | `.togglePlayPause` | `AudioController.togglePlayPause()` |
| `GCMicroGamepad.dpad.left.pressed` | debounced (100 ms) | `.previousPreset` | same as `leftArrow` |
| `GCMicroGamepad.dpad.right.pressed` | debounced (100 ms) | `.nextPreset` | same as `rightArrow` |

**Menu button does not exit.** The tvOS **Home/TV** button (hardware, distinct from Menu on Siri Remote 2nd-gen) is the only exit (per Q3 resolution). Implement by:
- Override `pressesBegan` on `VisualizerViewController`, intercept `.menu`, call handler, and **do NOT** call `super` for the `.menu` case. For all others, call `super` so tvOS gets a chance to handle edge cases.

Debounce (F18): `RemoteInputHandler` keeps `lastCommandTime`; commands within 100 ms of the previous `.nextPreset`/`.previousPreset` are dropped.

---

## 10. Error Handling & Recovery

| Failure mode | Detection | Recovery |
|---|---|---|
| EAGL context creation returns nil | `EAGLContext(api: .openGLES3) == nil` | Fatal; display `"OpenGL ES 3 not available"` full-screen label. Only affects non-A12+ devices, out of scope per A4. |
| GL context lost on backgrounding | `UIApplication.didEnterBackgroundNotification` | Pause CADisplayLink; on foreground, re-set current context. projectM instance is retained across backgrounding (tvOS preserves GL resources for recently-foregrounded apps). |
| GL context resources actually invalidated | Next `glGetError()` returns `GL_CONTEXT_LOST` (rare on tvOS; possible after long sleep) | Destroy `projectm_handle`, re-create via `projectm_create_with_opengl_load_proc`, reload current preset. Costs ~500 ms; acceptable. |
| MusicKit authorization denied | `MusicAuthorization.status != .authorized` after request | Disable Apple Music button in `SourcePickerView`; show inline explanation; do not block Local File mode (F26). |
| MusicKit playback error (subscription expired, item unavailable) | `ApplicationMusicPlayer.shared.state.playbackStatus == .paused` with `MusicPlayerError` | Surface error in overlay for 5 s; return to source picker. |
| Local file decode fails (`AVAudioFile(forReading:)` throws) | `throws` at playback start | Show toast, return to picker, remain in Local File mode. |
| Preset fails to parse/compile | `projectm_set_preset_switch_failed_event_callback` fires | `PresetLibrary` records failure, skips to `next()` automatically (F13). No user-visible error (F13). |
| Audio route change (HDMI swap) | `AVAudioSession.routeChangeNotification` / `AVAudioEngineConfigurationChange` | Tear down `AudioEngineSource`, rebuild with new format, resume playback from current position. |
| Ring buffer underflow | Consumer reads zero frames for > 500 ms | Feed silence to projectM (F8). Log debug. No user-visible change; projectM keeps rendering. |
| Ring buffer overflow | Producer sees write head catching read head | Drop oldest frame, advance read head. Log at `debug`. Inaudible to projectM's FFT. |
| `projectm_create_*` returns NULL | Check return value | Log fatal, show "Rendering engine failed to start"; retry after 1 s; if still fails, exit app (no graceful recovery). |

---

## 11. Testing Strategy

### 11.1 Unit Tests (XCTest, in `projectm-tvTests`)

1. **`PCMRingBufferTests`** — SPSC correctness: multi-threaded producer/consumer for 1 M samples, verify no lost/duplicated samples; overflow and underflow semantics; wraparound at capacity boundary.
2. **`PresetLibraryTests`** — given a fixture directory with 50 `.milk` files and some non-`.milk` cruft, enumerate returns exactly the 50; shuffle differs between runs; history ring wraps at 64; failed URLs are excluded on subsequent shuffles.
3. **`ProceduralPCMGeneratorTests`** — given `bpm=120`, running the generator for 1 s produces 2 beat peaks (locate peaks by envelope amplitude); carrier is non-zero; channels are independent (L and R buffers should not be bit-identical due to random seed in pink noise).
4. **`RemoteInputHandlerTests`** — sequence of `UIPress` fakes produces correct command stream; debounce correctly coalesces rapid repeats.

### 11.2 Integration Test (XCUITest, in `projectm-tvUITests`)

- **`LaunchTests`**: launch the app, wait for source picker to appear, select Local File → pick a fixture file bundled in the test target, assert `CADisplayLink` ticks ≥ 300 times within 5 s without an unhandled exception. Pass criterion: the app renders ≥ 300 frames and does not crash.
- This is the only UI test (A10 allows manual only; we run one as a smoke test).

### 11.3 Manual Test Plan

Per-milestone acceptance (executed on Apple TV 4K 2nd gen, tvOS 17+):

- **M4 (Black screen):** app launches, shows a black GLKView for 10 s without crash.
- **M5 (Idle visualizer):** app launches, shows animated idle preset (projectM's default `"idle://"` scene).
- **M6 (Local file reactive):** pick a known `.mp3`, visualizer pulses on beat visibly.
- **M7 (MusicKit procedural):** start Apple Music track, visualizer reacts to *procedural* beat grid (not the actual audio) — acceptable and documented.
- **M8 (Remote):** swipe left/right cycles presets <300 ms; center click toggles lock; menu toggles overlay.
- **M9 (Overlay UI):** overlay shows preset name + track metadata; auto-hides after 5 s.
- **M10 (TestFlight):** upload succeeds, TestFlight internal install succeeds, device installs build, AC1–AC14 all green.

### 11.4 Frame-Rate Instrumentation

- `DisplayLinkDriver` records frame-time EMA and exposes it to `AppState` (debug-only).
- Debug build: top-right corner shows "60.0 fps / 16.6 ms" in 12 pt SF Mono (removed for Release).
- For AC7 acceptance: Xcode Instruments "GPU" + "Core Animation FPS" over a 2-minute scripted sweep of 10 curated presets (hard-coded list in `PresetLibrary.debugReferenceSweep`).

---

## 12. Risks & Mitigations

| # | Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | libprojectM's GLES 3.2 floor (`GladLoader.cpp:50`) incompatible with tvOS EAGL (3.0) | **Critical** | High | Upstream edit (see §4.6 Edit 1). If renderer shaders use GLSL 3.20-only features, downgrade the `#version` pragma or emulate. Surface M1 gate: if fundamental features are missing, scope flips to Metal (v2) for v1 — would be a hard reset. |
| R2 | On-Apple-TV GL function resolution fails because `libGLESv2.dylib` not present | High | High | Always use `projectm_create_with_opengl_load_proc` with a `dlsym(RTLD_DEFAULT, …)` load_proc. Fallback is Upstream Edit 2 (§4.6). |
| R3 | Apple Music PCM tap impossibility = inferior UX | Medium | Certain | Procedural driver (§3.5) + clear disclosure in app + TestFlight notes. v2 idea: sync to `MPNowPlayingInfoCenter` beat events if Apple ever exposes them. |
| R4 | OpenGL ES deprecation: Apple removes EAGL in some future tvOS | Medium | Low (short term) | Already scoped: Metal port is v2. For v1, pin `TARGETED_DEVICE_FAMILY` and keep tvOS minimum at 17.0; if tvOS 18/19 removes EAGL we'll know from the beta SDK and can accelerate v2. |
| R5 | Preset pack license ambiguity for redistribution | Low | Low | User has confirmed `LICENSE.md` permits personal-use embedding. TestFlight is "personal distribution to registered testers" — well inside any reasonable permissive reading. Bundle LICENSE.md visibly (§8.3). |
| R6 | Remote gesture accidents (user swipes past many presets by accident) | Low | Medium | 100 ms debounce (F18) + overlay shows current preset name so user can confirm landing. |
| R7 | Preset-compilation failures > 5% (violates N6) | Medium | Unknown | Mitigation is pack curation: developer runs a pre-flight sweep on desktop with this projectM build, removes offending presets locally before `sync-preset-pack.sh`. Add `scripts/validate-presets.sh` to automate. |
| R8 | CADisplayLink stalls during heavy preset (violates AC7) | Medium | Medium | Drop `contentScaleFactor` to 1.0 (1080p backing store); reduce mesh size via `projectm_set_mesh_size(48, 32)` from default 32×24 only if that helps; curate out the worst offenders. |
| R9 | projectm-eval tree-walking interpreter flagged by App Review as "downloadable code" | Low | Low | Per N10 the interpreter is acceptable. Preset text is bundled *in the app*, never downloaded at runtime. TestFlight review is more lenient than full App Store review; if flagged, the relevant Apple precedent for Milkdrop-style apps on the App Store is well-established. |
| R10 | Memory pressure from many active projectM textures on 4K | Medium | Low | N2 = 512 MB budget. Curate preset pack (R7 applies). Monitor via Xcode Memory Graph. |

**Top 3 by severity × likelihood:** R1, R2, R3.

---

## 13. Milestones

Each milestone is a **demo-able state**. Build in strict order; do not skip.

| # | Milestone | Demo-able state | Gate criteria |
|---|---|---|---|
| **M1** | CMake tvOS target builds libprojectM | Running `scripts/build-libprojectm-xcframework.sh` completes without error for `appletvos`. | `libprojectM-4.a` exists under `build-tvos/appletvos/…`. GLES version floor compatible with tvOS (Edit 1 applied if needed). |
| **M2** | XCFramework produced | Both `appletvos` and `appletvsimulator` slices built and `xcodebuild -create-xcframework` bundles them. | `apps/tvos/Frameworks/libprojectM.xcframework/Info.plist` lists both slices. |
| **M3** | Xcode project opens and links | `projectm-tv.xcodeproj` builds for `generic/tvOS` and `tvOS Simulator` with only a `@main` empty SwiftUI app. XCFramework linked, bridging header imports `projectM-4/projectM.h`. | App builds and runs; shows empty screen; no linker errors. |
| **M4** | Black screen renders | `VisualizerViewController` creates EAGLContext, installs GLKView, drives CADisplayLink. `projectm_create_with_opengl_load_proc` returns non-null. `projectm_opengl_render_frame` called 60 Hz. | Black screen; profiler shows 60 fps sustained; no GL errors. |
| **M5** | Idle visualizer renders | `projectm_load_preset_file(..., "idle://", false)` called; default projectM "M" logo scene renders. Viewport handling correct at 4K. | Idle scene animates; correct aspect; 60 fps. |
| **M6** | Local file audio reactive | `AudioEngineSource` implemented + wired. Tap → ring buffer → projectM. Document picker integrated. Loops file (Q12). | Pick a `.mp3`, visualizer reacts to beats with <100 ms perceived latency. |
| **M7** | MusicKit auth + playback + procedural driver | `MusicKitSource` with procedural generator. Library browse stub (one song hard-coded or `MusicPersonalRecommendationsRequest`). | Start Apple Music playback, visualizer animates on synthetic beat grid. Limitation disclosed in `AcknowledgementsView`. |
| **M8** | Remote input | `RemoteInputHandler` wired. Swipes cycle presets; center toggles lock; menu toggles overlay. Debounce works. | All rows in §9 mapping verified manually. |
| **M9** | Overlay UI | `OverlayView` displays preset name + now-playing + lock state. Auto-hide after 5 s. Dim underlay ≤30%. | AC6 passes. |
| **M10** | TestFlight upload | Archive + Validate + Upload. Internal tester install on device. AC1–AC14 all ticked. | Build available in TestFlight; tester installs and runs through 30-min session (AC8) without crash. |

Count: **10 milestones** (M1 through M10).

---

## 14. Open Items Reserved for Executor

None of these are blockers, but the Planner should carry them as explicit tasks:

1. Confirm whether Option A in §4.6 Edit 2 works (custom `load_proc` bypasses name-table probe). If yes, Edit 2 is zero lines. Verify in M1.
2. Decide MusicKit browse UI fidelity for v1. Current spec: three sections (Recently Played / Playlists / Songs). Executor may simplify to "last played track auto-resume" if the picker becomes a time sink. Mark as a v1.1 improvement if deferred.
3. Curate the preset sweep set for AC7 (10 representative presets). Developer selects from the `Fractal`, `Hypnotic`, and `Supernova` categories — these tend to stress both per-pixel meshes and texture bandwidth.

---

**End of spec.**
