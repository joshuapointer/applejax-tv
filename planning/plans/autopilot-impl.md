# projectM tvOS Visualizer — Implementation Plan

Executable plan derived from `requirements.md` and `spec.md`. Target: a TestFlight-ready personal tvOS app at `apps/tvos/` linking libprojectM via XCFramework.

**Hard gate:** Milestone M1 is a go/no-go gate. If libprojectM cannot be built for tvOS device+simulator with GLES 3.0, the project flips to Metal v1 (scope change requiring re-planning). Do NOT begin M3+ work until M1 and M2 are green.

**Xcode project approach (chosen):** **XcodeGen** (`project.yml`). Rationale: text-editable, reviewable in diffs, CI-friendly, trivially regenerable. Alternatives rejected — hand-authored `project.pbxproj` is unreviewable in PRs; tuist is heavier than needed for a single-target personal app. **The generated `projectm-tv.xcodeproj` is gitignored**; developers run `xcodegen generate` after every `project.yml` change (documented in `README.md`).

**Signing:** Manual signing. `TEAM_ID_PLACEHOLDER` placeholder in `project.yml`; developer sets their real team ID via a local `xcconfig` untracked in git. Instructions in `apps/tvos/README.md`.

**Total task count:** 58 tasks across 10 milestones + 3 cross-cutting tasks (tests, README, preset-pack validation script). Revisions incorporate critic feedback (5 critical + 6 major findings addressed).

---

## M1 — CMake tvOS target builds libprojectM (HARD GATE)

### T01 — Create CMake toolchain file for tvOS
- **Milestone:** M1
- **Depends on:** —
- **Files:** `apps/tvos/scripts/toolchains/tvos.cmake` (new)
- **Description:** Author toolchain file per spec §4.1. Sets `CMAKE_SYSTEM_NAME=tvOS`, `CMAKE_OSX_DEPLOYMENT_TARGET=17.0`, forces `BUILD_SHARED_LIBS=OFF`, `ENABLE_GLES=ON`, disables SDL/playlist/tests/install. Adds `PROJECTM_TVOS=1` and `USE_GLES=1` compile definitions. Caller picks SDK via `-DCMAKE_OSX_SYSROOT=appletvos` or `appletvsimulator`.
- **Acceptance:** (1) `cmake -S . -B /tmp/tvtest -G Xcode -DCMAKE_TOOLCHAIN_FILE=apps/tvos/scripts/toolchains/tvos.cmake -DCMAKE_OSX_SYSROOT=appletvos` configures without error; (2) CMake cache shows `PROJECTM_TVOS=1`; (3) `ENABLE_GLES=ON` confirmed.
- **Parallel with:** T02, T06
- **Complexity:** simple
- **LoC:** <50

### T02 — Write preset-pack sync script
- **Milestone:** M1 (cross-cutting, placed here for early availability)
- **Depends on:** —
- **Files:** `apps/tvos/scripts/sync-preset-pack.sh` (new), `apps/tvos/Resources/presets/.gitkeep` (new)
- **Description:** Bash script that rsyncs `~/Music/projectm-presets/` into `apps/tvos/Resources/presets/`, excluding dotfiles. Also copies `~/Music/projectm-presets/LICENSE.md` verbatim. Idempotent (`--delete`). Set exec perms via `chmod +x`.
- **Acceptance:** (1) Running the script populates `apps/tvos/Resources/presets/` with 13 category dirs + LICENSE.md + README.md; (2) re-running cleans orphaned files.
- **Parallel with:** T01, T06
- **Complexity:** simple
- **LoC:** <50

### T03 — Apply GladLoader GLES-floor patch (upstream Edit 1)
- **Milestone:** M1
- **Depends on:** T01
- **Files:** `src/libprojectM/Renderer/Platform/GladLoader.cpp` (modify, lines 46–54 area)
- **Description:** Per spec §4.6 Edit 1: introduce `#if defined(PROJECTM_TVOS) || defined(PROJECTM_IOS)` branch that relaxes GLES minimum to 3.0 and GLSL to 3.00, guarded so desktop path is unchanged. Five-to-ten line change, all behind guard.
- **Acceptance:** (1) Desktop GLES path unchanged (compile-check passes with no `PROJECTM_TVOS` define); (2) With `PROJECTM_TVOS=1`, `glCheck.WithMinimumVersion(3,0)` is the effective path.
- **Parallel with:** T04
- **Complexity:** simple
- **LoC:** <50

### T04 — Verify GL loader probe behavior with custom load_proc (Option A verification)
- **Milestone:** M1
- **Depends on:** T01, T03
- **Files:** No files modified; investigation task.
- **Description:** Per spec §4.6 Edit 2 Option A: inspect `Renderer/Platform/GLResolver.cpp` and `GladLoader.cpp` to confirm that passing a user load_proc via `projectm_create_with_opengl_load_proc` bypasses `PlatformLibraryNames.hpp`'s dylib-name probe. Trace the code path. If Option A is proven, no upstream edit needed (skip T05). If probe still executes, schedule T05.
- **Acceptance:** Written determination in `.omc/autopilot/m1-loader-decision.md` stating: (a) which option applies, (b) code-path evidence (file:line references), (c) whether T05 must run.
- **Parallel with:** T03
- **Complexity:** standard
- **LoC:** <50 (decision doc only)

### T05 — Conditional: PlatformLibraryNames tvOS/iOS entry (upstream Edit 2)
- **Milestone:** M1
- **Depends on:** T04 (only runs if T04 concludes Option B needed)
- **Files:** `src/libprojectM/Renderer/Platform/PlatformLibraryNames.hpp` (modify lines 40–65)
- **Description:** Per spec §4.6 Edit 2 Option B. Add `#elif defined(__APPLE__) && (TARGET_OS_IOS || TARGET_OS_TV)` branch pointing at `/System/Library/Frameworks/OpenGLES.framework/OpenGLES`. Five-line addition, guarded.
- **Acceptance:** (1) Desktop macOS branch unchanged; (2) tvOS build resolves GL symbols without error.
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** <50

### T05b — GLResolver: recognize EAGL as valid backend on tvOS/iOS (upstream Edit 3 — CRITICAL)
- **Milestone:** M1
- **Depends on:** T01
- **Files:** `src/libprojectM/Renderer/Platform/GLResolver.cpp` (modify around lines 405-410 and 920-929)
- **Description:** Per critic finding C3. Current Apple branch of `ProbeCurrentContext` only detects CGL (macOS) via `CGLGetCurrentContext`. EAGL has no probe, so `Initialize()`'s `HasCurrentContext` gate at line 405 returns false on tvOS and `projectm_create_with_opengl_load_proc` returns NULL. Add `#if defined(PROJECTM_TVOS) || defined(PROJECTM_IOS)` branch in `ProbeCurrentContext` that: (a) checks `[EAGLContext currentContext] != nil` (via a small `.mm` helper if needed, or dlsym-lookup of `CurrentContext` symbol), OR (b) returns "has current context = true" unconditionally when `PROJECTM_TVOS` is defined with a fallback comment that the caller guarantees this invariant via `setCurrent` before calling `projectm_create_*`. Also tag the backend enum with an `EAGL` entry if required for downstream checks. Guarded so desktop behavior unchanged.
- **Acceptance:** (1) With `PROJECTM_TVOS=1`, `projectm_create_with_opengl_load_proc` returns non-NULL in a tvOS harness where `EAGLContext.setCurrent` was called first; (2) desktop macOS and Linux paths unchanged (compile-check + existing tests pass); (3) no behavior change when `PROJECTM_TVOS` is undefined.
- **Parallel with:** T03, T04
- **Complexity:** complex (requires reading GLResolver.cpp carefully and picking (a) or (b))
- **LoC:** 50–200

### T06 — Write XCFramework build script
- **Milestone:** M1
- **Depends on:** T01
- **Files:** `apps/tvos/scripts/build-libprojectm-xcframework.sh` (new)
- **Description:** Per spec §4.2. Bash script configures both `appletvos` and `appletvsimulator` builds with Xcode generator, builds `projectM` target in Release, then `xcodebuild -create-xcframework` bundles both `.a` slices with headers into `apps/tvos/Frameworks/libprojectM.xcframework`. Uses `set -euo pipefail`. Accepts optional `--clean` flag.
- **Acceptance:** (1) Script runs end-to-end without error; (2) `apps/tvos/Frameworks/libprojectM.xcframework/` exists with `Info.plist` listing both slices; (3) `tvos-arm64/libprojectM-4.a` and `tvos-arm64-simulator/libprojectM-4.a` both exist; (4) both slices include full `Headers/projectM-4/` tree.
- **Parallel with:** T01, T02 (author in parallel; executes after T01, T03 land)
- **Complexity:** standard
- **LoC:** 50–200

### T07 — M1 smoke: build libprojectM for tvOS device
- **Milestone:** M1
- **Depends on:** T01, T03, T04, T05 (conditional), T05b, T06
- **Files:** —
- **Description:** Execute `apps/tvos/scripts/build-libprojectm-xcframework.sh`. Confirm build succeeds end-to-end for both SDKs. If it fails, triage at the CMake error and either (a) fix the toolchain, (b) add a guarded upstream change, or (c) escalate as scope-change to Metal v1.
- **Acceptance:** (1) Script exits 0; (2) XCFramework artifact exists and `file` identifies both slices as arm64 static archives; (3) running `lipo -info` or `xcodebuild -checkFirstLaunchStatus` reports expected architectures.
- **Parallel with:** —
- **Complexity:** complex (may require debugging CMake/shader issues)
- **LoC:** 0 (verification)

---

## M2 — XCFramework produced

(M1's T06/T07 already produce the XCFramework; M2 is effectively a verification/packaging checkpoint.)

### T08 — XCFramework sanity validation
- **Milestone:** M2
- **Depends on:** T07
- **Files:** —
- **Description:** Run `xcrun xcodebuild -checkFirstLaunchStatus`; verify `libprojectM.xcframework/Info.plist` via `plutil` lists `AvailableLibraries` with both `appletvos` and `appletvsimulator` library identifiers. Confirm public headers at `<slice>/Headers/projectM-4/{projectM.h,audio.h,core.h,parameters.h,render_opengl.h,callbacks.h}`.
- **Acceptance:** (1) Both slices present with correct `SupportedPlatform`, `SupportedPlatformVariant`; (2) headers exist and parse without error (`clang -x c -E` on each).
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

---

## M3 — Xcode project opens and links

### T09 — Author XcodeGen `project.yml`
- **Milestone:** M3
- **Depends on:** T08
- **Files:** `apps/tvos/project.yml` (new)
- **Description:** XcodeGen spec for a single tvOS app target `projectm-tv` (+ `projectm-tvTests`, `projectm-tvUITests`). Bundle ID `com.joshpointer.projectm-tv`. Deployment target tvOS 17.0. Swift 5.9. Includes sources from `projectm-tv/**/*.swift`, bridging header, `Frameworks/libprojectM.xcframework` as non-embedded framework, link system frameworks per spec §4.3 (OpenGLES, MusicKit, AVFoundation, GameController, CoreMedia, GLKit, UIKit), resources including `Resources/presets` as folder reference and `Resources/Licenses` and `Resources/samples`. Signing style "Manual" with team ID placeholder. Code-sign identity `Apple Development`. Entitlements file path set. Test-bundle resource entries include a sample audio fixture for T49's `LaunchTests` UI test.
- **Acceptance:** (1) `xcodegen generate --spec apps/tvos/project.yml` produces `projectm-tv.xcodeproj`; (2) `xcodebuild -list -project apps/tvos/projectm-tv.xcodeproj` lists the three targets; (3) `projectm-tv.xcodeproj` is gitignored (see T51).
- **Parallel with:** T10, T11, T12, T13
- **Complexity:** standard
- **LoC:** 50–200 (YAML)

### T10 — Write Info.plist
- **Milestone:** M3
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Info.plist` (new)
- **Description:** tvOS Info.plist with `CFBundleIdentifier=com.joshpointer.projectm-tv`, `CFBundleDisplayName=projectM`, `LSRequiresIPhoneOS` NOT set (tvOS), `UIRequiredDeviceCapabilities=[arm64, opengles-3]`, `UILaunchScreen` empty dict, `NSAppleMusicUsageDescription="projectM needs access to your Apple Music library to play and visualize tracks."`, `UIApplicationSupportsIndirectInputEvents=YES`. `MinimumOSVersion=17.0`.
- **Acceptance:** (1) `plutil -lint` passes; (2) all required keys present.
- **Parallel with:** T09, T11, T12, T13
- **Complexity:** simple
- **LoC:** <50

### T11 — Write entitlements file
- **Milestone:** M3
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/projectm_tv.entitlements` (new)
- **Description:** Entitlements plist with `com.apple.developer.musickit = true`. Nothing else.
- **Acceptance:** (1) `plutil -lint` passes; (2) `com.apple.developer.musickit` boolean true present.
- **Parallel with:** T09, T10, T12, T13
- **Complexity:** simple
- **LoC:** <50

### T12 — Create Assets catalog (AppIcon, TopShelf, LaunchImage)
- **Milestone:** M3
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Assets.xcassets/` (new tree with Contents.json files). Placeholder SF Symbol or solid-color PNGs for icon layers.
- **Description:** tvOS requires layered `AppIcon.brandassets` (front/middle/back layers at 1280×768) and `TopShelfImage.brandassets`. Create the catalog structure with placeholder images (can be solid dark-purple + "projectM" text). Full-fidelity icons can be v1.1.
- **Acceptance:** (1) `xcodebuild build` completes without icon errors; (2) asset catalog validates when archiving.
- **Parallel with:** T09, T10, T11, T13
- **Complexity:** standard
- **LoC:** <50 (mostly JSON + small PNGs)

### T13 — Create Swift bridging header
- **Milestone:** M3
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Visualizer/ProjectMBridge.h` (new)
- **Description:** Objective-C bridging header that imports all public projectM headers per spec §4.3. Includes `<dlfcn.h>` and `<OpenGLES/ES3/gl.h>` for subsequent GL helpers.
- **Acceptance:** (1) Bridging header path referenced in `project.yml`; (2) `#import` statements parse without missing-header errors when XCFramework is linked.
- **Parallel with:** T09, T10, T11, T12
- **Complexity:** simple
- **LoC:** <50

### T14 — M3 smoke: minimal SwiftUI @main builds and runs
- **Milestone:** M3
- **Depends on:** T09, T10, T11, T12, T13
- **Files:** `apps/tvos/projectm-tv/App/ProjectMTVApp.swift` (new), `apps/tvos/projectm-tv/App/Logger.swift` (new)
- **Description:** Minimum SwiftUI app: `@main struct ProjectMTVApp: App` with a `WindowGroup { Text("projectM tvOS") }`. `Logger.swift` wraps `os.Logger` with a single `logger` global. Must link successfully against the XCFramework (bridging header imported).
- **Acceptance:** (1) `xcodebuild -project apps/tvos/projectm-tv.xcodeproj -scheme projectm-tv -destination 'generic/platform=tvOS' build` succeeds; (2) `xcodebuild -destination 'platform=tvOS Simulator,name=Apple TV'` builds and installs; (3) app launches in simulator and displays "projectM tvOS" text.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

---

## M4 — Black screen renders

### T15 — `EAGLContextFactory` + `EAGLContext` creation
- **Milestone:** M4
- **Depends on:** T14
- **Files:** `apps/tvos/projectm-tv/Visualizer/EAGLContextFactory.swift` (new)
- **Description:** Static factory `EAGLContextFactory.makeContext() -> EAGLContext?`. Returns `EAGLContext(api: .openGLES3)` or nil. Includes a helper `withCurrent(_ block: () -> Void)` to scope `setCurrent`/clear.
- **Acceptance:** (1) Unit test creates a context and reports `nil` only on unsupported devices; (2) `api == .openGLES3` verified.
- **Parallel with:** T16, T17
- **Complexity:** simple
- **LoC:** <50

### T16 — `DisplayLinkDriver`
- **Milestone:** M4
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Visualizer/DisplayLinkDriver.swift` (new)
- **Description:** Wraps `CADisplayLink` with `preferredFramesPerSecond = 60`. Exposes `start(_ tick: @escaping () -> Void)`, `pause()`, `stop()`. Tick invoked on main thread.
- **Acceptance:** (1) Unit test verifies tick is called ≥50 times per second on main; (2) `stop()` stops all callbacks.
- **Parallel with:** T15, T17
- **Complexity:** simple
- **LoC:** <50

### T17 — GL load_proc bridge (ObjC helper for `dlsym`)
- **Milestone:** M4
- **Depends on:** T13
- **Files:** `apps/tvos/projectm-tv/Visualizer/ProjectMBridge.m` (new)
- **Description:** Objective-C file exporting a C function `void* projectm_tv_gl_load_proc(const char* name)` that calls `dlsym(RTLD_DEFAULT, name)`. Header declaration in `ProjectMBridge.h`. Used as the `load_proc` argument to `projectm_create_with_opengl_load_proc`.
- **Acceptance:** (1) Resolves `glGetString` to a non-null function pointer in-app; (2) Swift can call the function via bridging header.
- **Parallel with:** T15, T16
- **Complexity:** simple
- **LoC:** <50

### T18 — `VisualizerViewController` + `GLKView` host
- **Milestone:** M4
- **Depends on:** T15, T16, T17
- **Files:** `apps/tvos/projectm-tv/Visualizer/VisualizerViewController.swift` (new), `apps/tvos/projectm-tv/Views/VisualizerContainerView.swift` (new)
- **Description:** `UIViewController` whose `view` is a `GLKView`. Creates EAGLContext, assigns to `GLKView.context`, sets drawable formats per spec §6.1, installs `CADisplayLink` via `DisplayLinkDriver`. Implements `glkView(_:drawIn:)`. On each tick: `setNeedsDisplay()`. Currently draws solid black via `glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT)`. `VisualizerContainerView` is a `UIViewControllerRepresentable` wrapper.
- **Acceptance:** (1) Launching app shows black fullscreen; (2) no GL errors via `glGetError` when instrumented; (3) `Logger` emits ~60 ticks/sec debug logs.
- **Parallel with:** T19
- **Complexity:** standard
- **LoC:** 200–500

### T19 — `AppState` bootstrap + root view wiring
- **Milestone:** M4
- **Depends on:** T18
- **Files:** `apps/tvos/projectm-tv/App/AppState.swift` (new), `apps/tvos/projectm-tv/Views/RootView.swift` (new), update `ProjectMTVApp.swift`
- **Description:** `@Observable final class AppState` with `phase`, `activeSource`, `isLocked`, `isOverlayVisible`, `currentPresetName`, `nowPlaying`, `musicAuthorization` per spec §3.10. `RootView` switches between `SourcePickerView` (stub) and `VisualizerContainerView` based on `phase`. For M4 default `phase = .visualizing` so we land on the black screen.
- **Acceptance:** (1) App launches into `VisualizerContainerView`; (2) black screen renders at 60 fps; (3) no runtime warnings.
- **Parallel with:** T18
- **Complexity:** standard
- **LoC:** 50–200

### T20 — M4 smoke: 60 fps black screen for 10 s
- **Milestone:** M4
- **Depends on:** T18, T19
- **Files:** —
- **Description:** Launch in simulator; verify via Xcode Debug Gauges that frame rate is 60 fps for 10 s without CADisplayLink stalls.
- **Acceptance:** (1) fps ≥ 58; (2) no crashes.
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

### T20b — Background/foreground lifecycle (F27, CRITICAL per critic C5)
- **Milestone:** M4
- **Depends on:** T18
- **Files:** Update `VisualizerViewController.swift`, add `apps/tvos/projectm-tv/App/AppLifecycleObserver.swift` (new)
- **Description:** Install observers for `UIApplication.didEnterBackgroundNotification`, `willEnterForegroundNotification`, `willResignActiveNotification`, `didBecomeActiveNotification`. On background/resign-active: `DisplayLinkDriver.pause()`, `AudioController.pause()`, `glFinish()`. On foreground/active: re-set `EAGLContext.setCurrent(context)`, `DisplayLinkDriver.resume()`, resume audio only if user had it playing before. On `GL_CONTEXT_LOST` (detect via `glGetError` after foregrounding): destroy and recreate `projectm_handle`, reload current preset. Per spec §6.4 and §10.
- **Acceptance:** (1) App backgrounded via home button then returned: resumes rendering within 500 ms, no crash; (2) 5-minute sleep simulation recovers cleanly; (3) audio is paused during background (verified via system volume indicator); (4) context-lost path code-covered by unit test or manual chaos injection.
- **Parallel with:** T20
- **Complexity:** standard
- **LoC:** 50–200

### T20c — `AppState` persistence wiring (F23, F24, AC10, CRITICAL per critic C1)
- **Milestone:** M4
- **Depends on:** T19
- **Files:** Update `App/AppState.swift`, add `apps/tvos/projectm-tv/App/AppStatePersistence.swift` (new)
- **Description:** On `AppState` init: read `UserDefaults.standard` keys `lastSourceMode` (String: "idle"|"appleMusic"|"localFile") and restore to `activeSource`; read `lastAutoAdvanceSeconds` (Double, default 30) and `lastTransitionSeconds` (Double, default 3) and apply via `ProjectMRenderer`. On `activeSource` change, persist. For F24 (MusicKit last queue item resume): persist `lastMusicKitTrackID` (String?) on `currentEntry` change in `MusicKitSource`, and on `start()` attempt `ApplicationMusicPlayer.shared.queue = [Song with that ID]` best-effort. **Explicitly do NOT persist**: `isLocked` (Q10), PCM samples, MusicKit tokens (F25).
- **Acceptance:** (1) Relaunch restores source mode; (2) Apple Music relaunch attempts to resume last track (best-effort, no crash if track unavailable); (3) AC11 audit confirms no token/PCM persistence; (4) test: kill-and-relaunch in simulator, source picker skipped, visualizer starts on restored source.
- **Parallel with:** T20, T20b
- **Complexity:** standard
- **LoC:** 50–200

---

## M5 — Idle visualizer renders

### T21 — `ProjectMRenderer` Swift wrapper
- **Milestone:** M5
- **Depends on:** T20
- **Files:** `apps/tvos/projectm-tv/Visualizer/ProjectMRenderer.swift` (new)
- **Description:** Swift class owning `projectm_handle`. Constructor: calls `projectm_create_with_opengl_load_proc(projectm_tv_gl_load_proc, nil)`; AFTER create (and after `setCurrent` on the EAGL context), sets initial viewport via `projectm_set_window_size`, sets `projectm_set_preset_duration(handle, 30.0)` for F11 auto-advance, and `projectm_set_soft_cut_duration(handle, 3.0)` for F12 transitions. Exposes `loadPreset(at:smooth:)`, `loadIdlePreset()`, `setLocked(_:)`, `setViewport(size:scale:)`, `addPCM(_:frameCount:channels:)`, `renderFrame(intoFBO: GLuint)` — uses `projectm_opengl_render_frame_fbo` (NOT `projectm_opengl_render_frame`) because `GLKView` rebinds its own FBO (non-zero), per critic major finding M1. Deinit calls `projectm_destroy`.
- **Acceptance:** (1) Instantiation returns a non-nil handle after `setCurrent` on EAGL context; (2) `renderFrame(intoFBO:)` produces no GL errors with `GLKView`'s current FBO; (3) `projectm_set_preset_duration` and `projectm_set_soft_cut_duration` are verified called via debug-logged `get_*` roundtrip.
- **Parallel with:** T22
- **Complexity:** standard
- **LoC:** 200–500

### T22 — Wire `ProjectMRenderer` into `VisualizerViewController`
- **Milestone:** M5
- **Depends on:** T21
- **Files:** Update `VisualizerViewController.swift`
- **Description:** Owner relationship: VC owns one `ProjectMRenderer`. On `viewDidLoad` (after `EAGLContext.setCurrent(context)`), create renderer. In `glkView(_:drawIn:)`, read current FBO via `glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo)` after `GLKView` has called `bindDrawable`, then call `renderer.renderFrame(intoFBO: GLuint(fbo))`. On `viewDidLayoutSubviews` and `traitCollectionDidChange`: call `setViewport`. On `didReceiveMemoryWarning`: log.
- **Acceptance:** (1) App launches and shows projectM's default idle scene animating INTO the GLKView drawable (not into FBO 0 / black); (2) 60 fps; (3) viewport matches screen at 4K.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

### T23 — M5 smoke: idle scene animates on Apple TV simulator
- **Milestone:** M5
- **Depends on:** T22
- **Files:** —
- **Description:** Run app in Apple TV 4K simulator; verify projectM idle logo animates; confirm no GL errors in console; confirm 60 fps.
- **Acceptance:** (1) Animated idle visible; (2) frame-time EMA <16.6 ms; (3) app stable for 60 s.
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

---

## M6 — Local file audio reactive

### T24 — `PCMRingBuffer` (lock-free SPSC)
- **Milestone:** M6
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Audio/PCMRingBuffer.swift` (new), `apps/tvos/projectm-tv/Util/LockFreeSPSC.swift` (new)
- **Description:** Lock-free single-producer single-consumer ring buffer per spec §3.6 and §5.3. Backed by `UnsafeMutablePointer<Float>` allocated once. Two `ManagedAtomic<UInt64>` (via `swift-atomics` SPM package or raw `_Atomic` in a thin C shim) for read/write heads. Capacity `max(4*576, 8192)` frames stereo. Producer writes interleaved LRLRLR float32 non-blocking; overflow drops oldest by advancing read head. Consumer reads up to N frames; underflow returns 0. No allocations in hot path.
- **Acceptance:** (1) Unit test `PCMRingBufferTests`: multi-threaded producer/consumer 1 M frames loses/duplicates 0 frames; (2) overflow test: continuous producer, zero consumer — size stays bounded at capacity; (3) wraparound at capacity boundary preserves data integrity; (4) zero allocations in hot path (verify with Instruments or `measureMetrics`).
- **Parallel with:** T25, T26, T27, T28
- **Complexity:** complex
- **LoC:** 200–500

### T25 — `AudioSource` protocol + `NowPlayingInfo` types
- **Milestone:** M6
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Audio/AudioController.swift` (new), `apps/tvos/projectm-tv/Audio/NowPlayingInfo.swift` (new)
- **Description:** Define `protocol AudioSource: AnyObject` per spec §3.2 with `start`, `pause`, `stop`, `nowPlaying`, `isPlayingPublisher`. Define `struct NowPlayingInfo` with `title`, `artist`, `album`, `bpm: Double?`. `AudioController` owns the current `AudioSource` and the `PCMRingBuffer`. Exposes `switchTo(_ source: AudioSourceKind)`. Also exposes `togglePlayPause()` (NOT on the protocol — on the router itself): when active source's `isPlayingPublisher` last emitted `true`, call `pause()`; otherwise call `start()`. This backs F17 / Siri Remote play-pause routing from T37.
- **Acceptance:** (1) Compiles; (2) switching source stops previous source before starting new; (3) only one source active at a time; (4) `togglePlayPause()` toggles playback state on the active source.
- **Parallel with:** T24, T26, T27, T28
- **Complexity:** standard
- **LoC:** 50–200

### T26 — `AudioEngineSource` (AVAudioEngine + tap)
- **Milestone:** M6
- **Depends on:** T24, T25
- **Files:** `apps/tvos/projectm-tv/Audio/AudioEngineSource.swift` (new)
- **Description:** Implements `AudioSource` for local files. Builds `AVAudioEngine` with `AVAudioPlayerNode` → `mainMixerNode` → `outputNode`. Installs tap on `mainMixerNode` (1024-frame buffer, at mixer's native format). Tap callback: converts `AVAudioPCMBuffer` from non-interleaved to interleaved LRLRLR float32 (`AVAudioConverter` if needed, pre-allocated converter object) and writes to the shared `PCMRingBuffer`. End-of-track handling per Q12: folder → advance alphabetically (wrap); single file → loop. Subscribes to `AVAudioEngineConfigurationChange` for route changes (spec §5.5).
- **Acceptance:** (1) Start with a known `.mp3`: PCM flows into ring buffer within 100 ms; (2) ring-buffer occupancy stays bounded; (3) folder advance advances to next file on completion; (4) route change rebuilds engine cleanly.
- **Parallel with:** T27, T28
- **Complexity:** complex
- **LoC:** 200–500

### T27 — Local file picker (tvOS document-picker equivalent)
- **Milestone:** M6
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Views/SourcePickerView.swift` (new), `apps/tvos/projectm-tv/Views/LocalFileBrowserView.swift` (new)
- **Description:** tvOS has NO `UIDocumentPickerViewController`. Workaround: use the bundled Test fixtures folder for v1 + a hardcoded "Play Sample Track" button wired to a bundled `sample.mp3` in `Resources/samples/`. Add a second option: browse a Bonjour/SMB network share via `FileManager` or a future companion-app drop — mark as v1.1 in a task comment. **v1 ships with the sample track + TestFlight "Sample Track" button only.** Document this limitation in `AcknowledgementsView` and README.
- **Acceptance:** (1) Tapping "Play Sample" starts playback; (2) no v1-blocking gap.
- **Parallel with:** T24, T25, T26, T28
- **Complexity:** standard
- **LoC:** 50–200

### T28 — Add a sample track to resources
- **Milestone:** M6
- **Depends on:** —
- **Files:** `apps/tvos/Resources/samples/sample.mp3` (new — public-domain or CC0 track). `apps/tvos/Resources/samples/LICENSE.md` (new — track attribution).
- **Description:** Add a short (~30 s) public-domain audio clip (e.g. from freesound.org CC0 category) to the bundle for M6 smoke and TestFlight demonstration. Include LICENSE.md attribution. Script fetches it or documents manual steps.
- **Acceptance:** (1) File exists in bundle after build; (2) LICENSE.md present and references CC0.
- **Parallel with:** T24, T25, T26, T27
- **Complexity:** simple
- **LoC:** <50 (+ binary asset)

### T29 — Wire audio into renderer's tick
- **Milestone:** M6
- **Depends on:** T22, T24, T26
- **Files:** Update `VisualizerViewController.swift`
- **Description:** On each display-link tick, BEFORE `renderer.renderFrame()`, drain up to `projectm_pcm_get_max_samples()` frames from the shared ring buffer into a stack buffer and call `renderer.addPCM(...)`. `AppState.audioController` is resolved via environment.
- **Acceptance:** (1) With `AudioEngineSource` playing, visualizer reacts to beats; (2) <100 ms end-to-end audio-to-visual latency (subjective).
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

### T30 — M6 smoke: beat-reactive visuals
- **Milestone:** M6
- **Depends on:** T27, T28, T29
- **Files:** —
- **Description:** Launch app in Apple TV simulator, tap "Play Sample Track". Confirm visualizer pulses on beats. Verify ring-buffer occupancy logs show bounded oscillation. No crashes over 2-minute play-through.
- **Acceptance:** (1) Visible beat-sync; (2) no stalls; (3) 60 fps sustained.
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

---

## M7 — MusicKit auth + playback + procedural driver

### T31 — `ProceduralPCMGenerator`
- **Milestone:** M7
- **Depends on:** T24
- **Files:** `apps/tvos/projectm-tv/Audio/ProceduralPCMGenerator.swift` (new), `apps/tvos/projectm-tv/Util/BPMEstimator.swift` (new)
- **Description:** Real-time thread that generates 48 kHz stereo float PCM per spec §3.5. Carrier: −24 dBFS pink noise (Voss-McCartney or Paul Kellet filter). Beat pulses: 50 ms exponential-envelope burst at beat interval `60/bpm` seconds, at −6 dBFS. Bar boundary (every 4 beats): LF amplitude modulation on carrier. Writes 1024-frame chunks to shared `PCMRingBuffer`. Accepts `setBPM(_:)` and `setPlaying(_:)`. `BPMEstimator` is a utility (fallback when MusicKit tempo missing → default 120).
- **Acceptance:** (1) Unit test `ProceduralPCMGeneratorTests`: bpm=120, 1 s of output has 2 detectable peaks in envelope; (2) carrier non-zero; (3) L/R channels differ; (4) `setPlaying(false)` produces silence.
- **Parallel with:** T32, T33
- **Complexity:** complex
- **LoC:** 200–500

### T32 — `MusicKitSource`: authorization, playback, metadata
- **Milestone:** M7
- **Depends on:** T25, T31
- **Files:** `apps/tvos/projectm-tv/Audio/MusicKitSource.swift` (new)
- **Description:** Implements `AudioSource`. Uses `ApplicationMusicPlayer.shared`. Handles `MusicAuthorization.request()`. Subscribes to `player.state.values` and `player.queue.$currentEntry.values`. On currentEntry change: if `Song`, read `song.tempo`; else 120 BPM; call `ProceduralPCMGenerator.setBPM(_:)`. On playback status change: `setPlaying(_:)`. Surfaces `NowPlayingInfo(title, artist, album, bpm)` on each track change. Handles denial per spec §7.1.
- **Acceptance:** (1) Auth prompt appears on first activation; (2) with auth granted, selecting a track starts playback; (3) `currentEntry` changes update `AppState.nowPlaying`; (4) procedural generator tracks BPM of current song.
- **Parallel with:** T31, T33
- **Complexity:** complex
- **LoC:** 200–500

### T33 — MusicKit minimal browse UI
- **Milestone:** M7
- **Depends on:** T32
- **Files:** `apps/tvos/projectm-tv/Views/MusicKitBrowserView.swift` (new), update `SourcePickerView.swift`
- **Description:** For v1 minimum viable browse: three sections — "Recently Played" (`MusicRecentlyPlayedRequest`), "Playlists" (`MusicLibraryRequest<Playlist>`), "Songs" (`MusicLibraryRequest<Song>` limited to 100). tvOS-friendly list navigation (SwiftUI `List` with `NavigationStack`). On row tap: set queue + play. Per spec §7.2, this is the one real concession outside black-screen scope. If implementation exceeds ~4 hours, fall back to a single "Play My Last Played Song" button + note in README as v1.1 improvement.
- **Acceptance:** (1) List populates after auth; (2) tapping a row starts playback and `MusicKitSource` reports the right track; (3) navigating back returns to picker.
- **Parallel with:** —
- **Complexity:** complex
- **LoC:** 200–500

### T34 — M7 smoke: procedural visuals sync to Apple Music track
- **Milestone:** M7
- **Depends on:** T32, T33
- **Files:** —
- **Description:** Manual: auth + pick a track with known BPM (e.g. a pop song around 120). Confirm visuals react to synthetic beat grid. Visuals change tempo when next track (different BPM) starts. Disclosure banner in `AcknowledgementsView` makes limitation explicit.
- **Acceptance:** (1) Visuals animate during Apple Music playback; (2) visible BPM change on track change (when BPMs differ); (3) limitation disclosed in `AcknowledgementsView`.
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

---

## M8 — Remote input

### T35 — `InputCommand` enum + `RemoteInputHandler`
- **Milestone:** M8
- **Depends on:** T22
- **Files:** `apps/tvos/projectm-tv/Input/InputCommand.swift` (new), `apps/tvos/projectm-tv/Input/RemoteInputHandler.swift` (new)
- **Description:** `enum InputCommand { case previousPreset, nextPreset, toggleLock, showOverlay, hideOverlay, togglePlayPause }`. `RemoteInputHandler` is attached to `VisualizerViewController`; overrides `pressesBegan`/`pressesEnded`. Maps `UIPress.PressType` per spec §9 table. Debounces `.previousPreset`/`.nextPreset` with a 100 ms window. Does NOT forward `.menu` to `super`. Commands published via a closure or `AsyncStream`.
- **Acceptance:** (1) Unit test `RemoteInputHandlerTests`: synthetic `UIPress` sequences produce correct command streams; (2) debounce coalesces 5 rapid presses within 100 ms into 1 command.
- **Parallel with:** T36
- **Complexity:** standard
- **LoC:** 200–500

### T36 — `PresetLibrary`
- **Milestone:** M8
- **Depends on:** T21
- **Files:** `apps/tvos/projectm-tv/Presets/PresetLibrary.swift` (new), `apps/tvos/projectm-tv/Presets/PresetManifest.swift` (new)
- **Description:** Walks `Bundle.main.bundleURL/presets` recursively, collects `.milk` files. **Excludes the `! Transition` subdirectory** — its contents are transition helpers, not standalone scenes (per critic finding). Shuffles. Maintains a history ring of 64. `next()`/`previous()`/`current()`. Registers a projectM preset-switch-failed callback via `projectm_set_preset_switch_failed_event_callback`; failed URLs go into a `failed` set and are not reselected. Emits current preset name to `AppState.currentPresetName`. Also defines `debugReferenceSweep: [URL]` — 10 curated presets (from `Fractal`, `Hypnotic`, `Supernova` categories per spec §14) used by T45 archive verification.
- **Acceptance:** (1) Unit test `PresetLibraryTests`: fixture dir with 50 `.milk` + cruft enumerates exactly the 50; (2) `! Transition` directory contents never returned from enumeration; (3) shuffle differs across instances; (4) history ring wraps; (5) failed URLs excluded; (6) `debugReferenceSweep` has exactly 10 URLs.
- **Parallel with:** T35
- **Complexity:** standard
- **LoC:** 200–500

### T37 — Wire input → preset / lock / overlay actions
- **Milestone:** M8
- **Depends on:** T35, T36, T19, T25
- **Files:** Update `VisualizerViewController.swift`, `AppState.swift`
- **Description:** Subscribe to `RemoteInputHandler` command stream in `VisualizerViewController`. Route: `.nextPreset` → `presetLibrary.next()` → `renderer.loadPreset(at:smooth:true)`; `.previousPreset` same pattern; `.toggleLock` → `renderer.setLocked(!AppState.isLocked)` + update state; `.showOverlay`/`.hideOverlay` → `AppState.isOverlayVisible` toggle; `.togglePlayPause` → `audioController.togglePlayPause()`.
- **Acceptance:** (1) Swipe L/R cycles presets <300 ms; (2) center click toggles lock (overlay lock icon reflects state); (3) menu toggles overlay.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

### T38 — M8 smoke: remote gesture acceptance
- **Milestone:** M8
- **Depends on:** T37
- **Files:** —
- **Description:** Run on simulator with "Apple TV Remote" enabled (Hardware → Show Apple TV Remote). Verify each mapping row in spec §9. Lock works (preset doesn't auto-advance). Overlay toggles.
- **Acceptance:** (1) All rows in spec §9 verified; (2) debounce visible (rapid swipes don't overshoot).
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

---

## M9 — Overlay UI

### T39 — `OverlayView` (SwiftUI)
- **Milestone:** M9
- **Depends on:** T37
- **Files:** `apps/tvos/projectm-tv/Views/OverlayView.swift` (new)
- **Description:** SwiftUI overlay bound to `AppState.currentPresetName`, `AppState.nowPlaying`, `AppState.isLocked`, `AppState.isOverlayVisible`. Layout per spec §3.9: bottom-left, ~25% screen height, `.ultraThinMaterial` background, rounded rectangle. Shows preset name + source label + title/artist/album (if present) + `Image(systemName: "lock.fill")` when locked. Auto-hide after 5 seconds of **no input** (F20 / AC6): maintain a `lastInteractionTime` in `AppState`; every input command in T37 refreshes it; a single `Task` checks elapsed time and hides when >5 s stale. Cancel/reset on any new command.
- **Acceptance:** (1) Overlay appears when `isOverlayVisible = true`; (2) displays live track + preset info; (3) fades out after 5 s of idle; (4) any remote input while visible resets the 5 s timer; (5) reappears on menu press.
- **Parallel with:** T40
- **Complexity:** standard
- **LoC:** 200–500

### T40 — Dim underlay + overlay compositing in `VisualizerViewController`
- **Milestone:** M9
- **Depends on:** T39
- **Files:** Update `VisualizerViewController.swift` and `VisualizerContainerView.swift`
- **Description:** When overlay visible, apply a 30% black `UIView` underlay behind the SwiftUI overlay so GL scene is dimmed without dropping below readable contrast. `UIViewControllerRepresentable` composites the SwiftUI overlay over the GLKView via `.overlay` modifier in the SwiftUI container.
- **Acceptance:** (1) Overlay readable over bright presets; (2) underlay removed when overlay hides; (3) dimming doesn't impact GL frame rate.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

### T41 — M9 smoke: overlay displays + auto-hides
- **Milestone:** M9
- **Depends on:** T40
- **Files:** —
- **Description:** Manual: press menu, confirm overlay visible with live metadata; wait 5 s, confirm auto-hide; press menu again, confirm reappear.
- **Acceptance:** (1) AC6 passes; (2) 60 fps maintained with overlay visible.
- **Parallel with:** —
- **Complexity:** simple
- **LoC:** 0 (verification)

---

## M10 — TestFlight upload

### T42 — `AcknowledgementsView` + license bundling
- **Milestone:** M10
- **Depends on:** —
- **Files:** `apps/tvos/projectm-tv/Views/AcknowledgementsView.swift` (new), `apps/tvos/Resources/Licenses/LGPL-2.1.txt` (copy from repo root `COPYING`), `apps/tvos/Resources/Licenses/projectM-attribution.md` (new), `apps/tvos/Resources/Licenses/preset-pack-license.md` (new — verbatim copy of `~/Music/projectm-presets/LICENSE.md`)
- **Description:** Per spec §8.3. LGPL-2.1 attribution, projectM GitHub URL, preset pack license text **included VERBATIM** (per critic major finding M6 — the preset pack LICENSE is opt-out not a grant, so the exact wording must be visible to any reviewer). Disclose: (a) Apple Music procedural-audio limitation, (b) AirPlay receiver unavailable, (c) no screensaver mode, (d) LGPL static-link stance for personal TestFlight use (object files available on request from developer — F43 README documents). Accessible from `SourcePickerView` via an "About" link.
- **Acceptance:** (1) View renders all three license blocks; (2) preset pack LICENSE text is verbatim (character-match against source); (3) Apple Music procedural-audio limitation visible; (4) LGPL text bundled; (5) no paraphrasing of any license.
- **Parallel with:** T43, T44
- **Complexity:** simple
- **LoC:** 50–200

### T43 — `README.md` for the tvOS app
- **Milestone:** M10
- **Depends on:** —
- **Files:** `apps/tvos/README.md` (new)
- **Description:** Build instructions: prereqs (Xcode 15+, XcodeGen installed via brew, CMake 3.26+, Apple Developer team ID). Step-by-step: (1) `scripts/build-libprojectm-xcframework.sh`; (2) `scripts/sync-preset-pack.sh`; (3) `xcodegen --spec project.yml`; (4) open project, set team ID in local xcconfig; (5) Archive. Troubleshooting section for M1 failure modes (GLES floor, loader probe). Known limitations section (Apple Music procedural audio, no AirPlay receiver, no screensaver, tvOS local file picker limitation).
- **Acceptance:** (1) A fresh clone + `./scripts/build-libprojectm-xcframework.sh` + `xcodegen` produces a buildable Xcode project from the README alone; (2) all known limitations documented.
- **Parallel with:** T42, T44
- **Complexity:** standard
- **LoC:** 200–500

### T44 — Signing config via local xcconfig
- **Milestone:** M10
- **Depends on:** T09
- **Files:** `apps/tvos/Signing.xcconfig.template` (new, tracked), `apps/tvos/.gitignore` entry adding `Signing.xcconfig`.
- **Description:** `Signing.xcconfig.template` has `DEVELOPMENT_TEAM = TEAM_ID_PLACEHOLDER` and `CODE_SIGN_STYLE = Manual`. Developer copies to `Signing.xcconfig` and sets real team ID. `project.yml` references `Signing.xcconfig`. `.gitignore` excludes the real file.
- **Acceptance:** (1) Template in repo; (2) real xcconfig gitignored; (3) Xcode picks up the team ID from the local xcconfig.
- **Parallel with:** T42, T43
- **Complexity:** simple
- **LoC:** <50

### T45 — Archive + validate build
- **Milestone:** M10
- **Depends on:** T41, T42, T43, T44
- **Files:** —
- **Description:** Run `xcodebuild archive -scheme projectm-tv -destination 'generic/platform=tvOS' -archivePath build/projectm-tv.xcarchive`. Then `xcodebuild -exportArchive -exportOptionsPlist scripts/exportOptions.plist -archivePath build/projectm-tv.xcarchive -exportPath build/ipa`. Requires signing config set.
- **Acceptance:** (1) `.xcarchive` produced; (2) export produces a signed `.ipa`; (3) `xcrun altool --validate-app` (or `xcrun notarytool` equivalent for App Store) validates.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** <50 (exportOptions.plist)

### T46 — TestFlight upload
- **Milestone:** M10
- **Depends on:** T45
- **Files:** —
- **Description:** `xcrun altool --upload-app -f build/ipa/projectm-tv.ipa -t tvos --apiKey {KEY} --apiIssuer {ISSUER}` (or via Xcode Organizer). Populate TestFlight "What to Test" with known limitations (procedural audio for Apple Music, no AirPlay receiver, sample-track-only local file in v1).
- **Acceptance:** (1) Upload succeeds; (2) build appears in App Store Connect TestFlight within 15 min; (3) internal tester (developer's own Apple ID) can install on Apple TV hardware.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 0 (operational)

### T47 — M10 acceptance: AC1–AC14 checklist
- **Milestone:** M10
- **Depends on:** T46, T47a, T47b
- **Files:** `apps/tvos/ACCEPTANCE.md` (new)
- **Description:** Run through the 14 acceptance criteria from `requirements.md`. For each: status (pass/fail), notes, evidence (screenshot path or log excerpt). Includes the scripted **30-minute AC8 reliability test** (start playback, leave running for 30 min, confirm no crash and frame-time EMA stable) and the **10-preset AC7 sweep** (cycle through `PresetLibrary.debugReferenceSweep` with 2 minutes per preset, record fps via Instruments). Publishable for autopilot Phase 4 review.
- **Acceptance:** (1) All 14 ACs green or deliberately deferred with rationale; (2) document written; (3) AC7 and AC8 have recorded evidence (Instruments traces or frame logs).
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200 (markdown)

### T47a — Privacy / telemetry audit (AC11, N7, N8 — CRITICAL per critic C4)
- **Milestone:** M10
- **Depends on:** T45
- **Files:** Update `apps/tvos/ACCEPTANCE.md`
- **Description:** On the built `projectm-tv.app`: (1) run `otool -L projectm-tv.app/projectm-tv` and confirm ONLY Apple system dylibs linked (no Firebase, Sentry, Analytics SDKs, etc.); (2) install on Apple TV hardware, run for 10 minutes exercising every feature, capture network with Proxyman or Charles with Apple TV routing through developer Mac; (3) confirm zero outbound traffic except Apple-owned hosts (MusicKit CDN, Apple analytics opt-in is accepted); (4) `grep -r "NSPrivacyAccessedAPITypes" apps/tvos/` — Apple's privacy manifest (if required for tvOS 17 personal TestFlight) is present or documented as deferred. Record findings in `ACCEPTANCE.md` under AC11.
- **Acceptance:** (1) `otool -L` output recorded with no third-party dylibs; (2) network capture recorded (or screenshot); (3) no unexpected domains in capture.
- **Parallel with:** T47b, T46 cleanup
- **Complexity:** standard
- **LoC:** 0 (operational — results into ACCEPTANCE.md)

### T47b — Persistence verification (F23, F24, F25, AC10)
- **Milestone:** M10
- **Depends on:** T45, T20c
- **Files:** Update `apps/tvos/ACCEPTANCE.md`
- **Description:** Scripted test: (1) launch app, pick Apple Music mode, play a track; (2) force-quit (swipe up on multitasking); (3) relaunch; (4) confirm it returns to Apple Music mode without re-showing source picker; (5) confirm last track attempts to resume (or shows picker if unavailable); (6) `grep -r "UserDefaults" apps/tvos/projectm-tv/ | grep -v "// F25"` to audit that persisted keys are only `lastSource*` (not PCM, not tokens) per F25. Record in `ACCEPTANCE.md`.
- **Acceptance:** (1) Source mode restored on relaunch; (2) no token/PCM persistence; (3) F25 negative verification recorded.
- **Parallel with:** T47a
- **Complexity:** simple
- **LoC:** 0 (operational)

---

## Cross-cutting tasks

### T48 — Unit test targets
- **Milestone:** runs across M6/M7/M8
- **Depends on:** T24, T36, T31, T35 (tests authored alongside their units)
- **Files:** `apps/tvos/projectm-tvTests/PCMRingBufferTests.swift` (new), `ProceduralPCMGeneratorTests.swift` (new), `PresetLibraryTests.swift` (new), `RemoteInputHandlerTests.swift` (new)
- **Description:** XCTest unit tests per spec §11.1. Each test file is authored in the same PR as its subject (see ACs of T24/T31/T35/T36).
- **Acceptance:** (1) `xcodebuild test` runs all tests; (2) ≥90% line coverage on the four target modules; (3) all tests pass.
- **Parallel with:** (authored with unit)
- **Complexity:** standard
- **LoC:** 200–500 (total across 4 files)

### T49 — Launch UI test
- **Milestone:** M4
- **Depends on:** T20
- **Files:** `apps/tvos/projectm-tvUITests/LaunchTests.swift` (new)
- **Description:** XCUITest that launches the app, waits for `VisualizerContainerView`, asserts 300 `CADisplayLink` ticks within 5 s via a debug-only logging hook. Bundled fixture sample for audio-reactive M6 confirmation.
- **Acceptance:** (1) UI test passes in simulator; (2) no unhandled exceptions in 5 s.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

### T50 — Preset validation script (optional but recommended per spec R7)
- **Milestone:** M1 (pre-flight) — can run in parallel with M3+
- **Depends on:** T07
- **Files:** `apps/tvos/scripts/validate-presets.sh` (new)
- **Description:** Bash script that, for each `.milk` in `apps/tvos/Resources/presets/`, loads it against a desktop projectM build (or in the tvOS simulator via a small test harness) and records which presets fail to compile. Outputs `apps/tvos/Resources/presets/.validated.txt`. Non-blocking for TestFlight but reduces runtime failure rate (spec N6).
- **Acceptance:** (1) Script runs end-to-end; (2) produces validation report; (3) runnable via README instructions.
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

### T51 — Signing.xcconfig template & `.gitignore` updates
- **Milestone:** M3 (cross-cutting)
- **Depends on:** T09
- **Files:** Update `.gitignore` (repo root or `apps/tvos/.gitignore`)
- **Description:** Add `.gitignore` entries: `apps/tvos/Signing.xcconfig`, `apps/tvos/projectm-tv.xcodeproj/` (generated by XcodeGen, per critic major finding M2), `apps/tvos/Resources/presets/`, `apps/tvos/Frameworks/libprojectM.xcframework/`, `build-tvos/`, `*.xcarchive`, `*.ipa`, `xcuserdata/`, `DerivedData/`. Keep `apps/tvos/Resources/presets/.gitkeep` (used as placeholder) tracked via `!.gitkeep` negated pattern.
- **Acceptance:** (1) `git status` clean after build artifacts produced; (2) `projectm-tv.xcodeproj` is not tracked by git.
- **Parallel with:** T44
- **Complexity:** simple
- **LoC:** <50

### T52 — CI (optional, out of scope for v1 if time-constrained)
- **Milestone:** v1.1 deferred (listed for completeness)
- **Depends on:** —
- **Files:** `.github/workflows/build_tvos.yml` (new)
- **Description:** GitHub Actions workflow: macos-14 runner, Xcode 15, install XcodeGen via brew, run `./apps/tvos/scripts/build-libprojectm-xcframework.sh`, run `xcodegen`, `xcodebuild build`. No signing; just verify compilation. **Deferred — do not execute in v1 unless explicitly requested.**
- **Acceptance:** N/A (deferred).
- **Parallel with:** —
- **Complexity:** standard
- **LoC:** 50–200

---

## Parallel execution batches

Tasks are batched by dependency layer. Tasks in the same batch can execute simultaneously.

| Batch | Tasks | Notes |
|---|---|---|
| **B1** (M1 foundation) | T01, T02 | Toolchain + sync script; independent. |
| **B2** (M1 patches) | T03, T05b | GladLoader patch + GLResolver EAGL patch (critical per critic C3); can parallel. |
| **B3** (M1 verification) | T04 | GL loader behavior probe. |
| **B4** (M1 conditional) | T05 (only if T04 says Option B) | |
| **B5** (M1 build script) | T06 | Depends on T01 for toolchain consumption. |
| **B6** (M1 gate) | T07 | Sequential; must complete before M2+. |
| **B7** (M2) | T08 | Depends on T07. |
| **B8** (M3 authoring) | T09, T10, T11, T12, T13 | Five parallel authoring tasks. |
| **B9** (M3 smoke) | T14 | Depends on all of B8. |
| **B10** (M4 parallel) | T15, T16, T17 | Three parallel utilities. |
| **B11** (M4 integration) | T18 | Depends on all of B10. |
| **B12** (M4 app state) | T19 | Depends on T18. |
| **B12b** (M4 lifecycle + persistence) | T20b, T20c | Parallel; T20b depends on T18, T20c depends on T19. |
| **B13** (M4 smoke) | T20 | Depends on T18, T19, T20b, T20c. |
| **B14** (M5) | T21 (then T22) | Sequential; T22 integrates T21. |
| **B15** (M5 smoke) | T23 | |
| **B16** (M6 parallel) | T24, T25, T27, T28 | Four parallel. |
| **B17** (M6 integration) | T26 | Depends on T24, T25. |
| **B18** (M6 wire-in) | T29 | Depends on T22, T24, T26. |
| **B19** (M6 smoke) | T30 | |
| **B20** (M7 parallel) | T31, T32 (T32 needs T31 — so T31 first, then T32) | T31 is dependency-free; T32 needs T25, T31. |
| **B21** (M7 browse UI) | T33 | Depends on T32. |
| **B22** (M7 smoke) | T34 | |
| **B23** (M8 parallel) | T35, T36 | Two parallel. |
| **B24** (M8 wiring) | T37 | Depends on T35, T36, T19. |
| **B25** (M8 smoke) | T38 | |
| **B26** (M9) | T39 → T40 | Sequential. |
| **B27** (M9 smoke) | T41 | |
| **B28** (M10 parallel) | T42, T43, T44, T51 | Four parallel. |
| **B29** (M10 archive) | T45 | Depends on T41, T42, T43, T44. |
| **B30** (M10 audits) | T47a, T47b | Parallel; both depend on T45. |
| **B31** (M10 upload) | T46 | Depends on T45. |
| **B32** (M10 acceptance) | T47 | Depends on T46, T47a, T47b. |

Cross-cutting: T48, T49, T50 are authored alongside their dependency tasks; T52 is deferred.

**Critical path length:** ~18 serial dependency levels (B1 → B2 → B5 → B6 → B7 → B8 → B9 → B10 → B11 → B12 → B13 → B14 → B15 → B17 → B18 → B19 → B20 → B21 → B23 → B24 → B26 → B28 → B29).

**Parallelism opportunities:** B8 (5-way), B10 (3-way), B16 (4-way), B23 (2-way), B28 (4-way).

---

## Risks carried forward from the spec

- **R1 (GLES 3.2 floor):** If T07 fails on a shader-compilation error in the renderer's own shaders (not preset shaders), scope flips to Metal v1 — this is a hard reset and requires re-planning. Escalation: stop autopilot, report to user with specific shader names and proposed path.
- **R2 (GL loader probe):** T04 determines whether T05 is needed. Both options are small and proven.
- **R2b (GLResolver EAGL backend, NEW per critic C3):** Third upstream edit required in T05b; if T05b's chosen approach doesn't work, fall back to the alternative (probe via `[EAGLContext currentContext]` ObjC-bridge in a `.mm` helper). If both fail, escalate as scope change.
- **R3 (Apple Music DRM tap):** Mitigated by procedural generator. Disclose in `AcknowledgementsView`. No further carry.
- **R4 (deprecation of EAGL and GLKView):** Both deprecated but not removed on tvOS 17/18. Silence warnings via `@available`. Metal port remains v2.
- **R6 (gesture debounce):** Built into T35 as a core feature.
- **R7/R8 (preset compilation failures, display-link stalls at 4K):** T50 pre-validates; fallback to `contentScaleFactor=1.0` if fps drops (exercise in T45 review).
- **R11 (LGPL static-link obligation, NEW per critic M6):** For personal TestFlight use this is de-minimis, but T42 documents the stance and T43 README states object files available on request. No further action required for v1.

---

## Open items reserved from spec

Converted to executor notes:
- **M1 Option A/B verification** → T04.
- **MusicKit browse fidelity** → T33 (with explicit fallback to single-button mode if implementation exceeds 4 hours).
- **AC7 preset sweep curation** → T45's archive verification should exercise a representative 10-preset sweep; define the list in `PresetLibrary.debugReferenceSweep` as part of T36.

---

**End of plan.**
