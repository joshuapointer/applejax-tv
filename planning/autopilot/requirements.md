# projectM tvOS Visualizer — Requirements (v1)

Phase 0 / Analyst deliverable. Personal-use Apple TV music visualizer built on the projectM Milkdrop-compatible engine, distributed via TestFlight to a single developer's own device(s).

---

## 1. Product Summary

A tvOS app that renders projectM (Milkdrop-compatible) audio-reactive visuals fullscreen on Apple TV, driven by in-app Apple Music playback (MusicKit + AVAudioEngine PCM tap) with a local-file picker fallback. The app bundles a curated preset pack and is controlled by Siri Remote for preset navigation, lock, and overlay toggle. Distribution is TestFlight only; scope is strictly personal use on the developer's paid Apple Developer account.

---

## 2. User Stories

1. As a user, I want to launch the app on my Apple TV and see a visualizer running immediately, so that I get a zero-friction "ambient visual" experience.
2. As a user, I want to pick an Apple Music song, album, or playlist from inside the app, so that my library drives the visuals without needing a second device.
3. As a user, I want to play a local audio file (e.g. from a USB-imported source or via a Files provider picker), so that I can visualize audio that isn't in Apple Music.
4. As a user, I want to swipe left/right on the Siri Remote to change presets, so that I can manually explore the bundled pack.
5. As a user, I want to click the remote center to lock the current preset, so that a favorite scene stays on screen until I unlock it.
6. As a user, I want to press Menu/Back to toggle an overlay with now-playing info and current preset name, so that I can confirm state without leaving the visual.
7. As a user, I want the app to resume with my last-used audio source and preset lock state, so that relaunching is frictionless.
8. As a user, I want a decent-looking idle/attract state when no audio is playing, so that the app never looks broken on first launch.
9. As a user, I want visuals to run at 60fps on my Apple TV 4K, so that motion feels smooth.
10. As a user, I want no telemetry or account sign-ups beyond Apple's MusicKit consent, so that the app respects my privacy.

---

## 3. Functional Requirements

### Audio capture & PCM pipeline
- **F1.** App SHALL support two audio source modes selectable from the UI: (a) Apple Music (MusicKit) and (b) Local File.
- **F2.** In Apple Music mode, the app SHALL use MusicKit's `MusicPlayer`/`ApplicationMusicPlayer` to drive playback of user-selected songs, albums, or playlists from the user's Apple Music library/subscription.
- **F3.** App SHALL install an `AVAudioEngine` input tap (or equivalent supported mechanism) on the playback signal path, producing 32-bit float PCM frames at the engine's native sample rate (expected 44.1 or 48 kHz).
- **F4.** PCM frames SHALL be forwarded to the projectM instance via `projectm_pcm_add_float()` with correct channel count (`PROJECTM_STEREO` when stereo) and sample count per call not exceeding `projectm_pcm_get_max_samples()`.
- **F5.** Audio tap callback thread SHALL NOT block; PCM delivery to projectM SHALL be decoupled from the render thread via a lock-free or mutex-protected ring buffer consumed on the GL render thread.
- **F6.** In Local File mode, the app SHALL accept audio files via the tvOS document picker (UIDocumentPickerViewController or SwiftUI equivalent) from user-granted Files providers (iCloud Drive, third-party providers), supporting at minimum `.mp3`, `.m4a`, `.wav`, `.aac`, `.flac` where the OS AVFoundation codec set permits.
- **F7.** The app SHALL tap Local File playback through the same `AVAudioEngine` PCM path so projectM receives identical PCM regardless of source.
- **F8.** When audio is paused/stopped, the app SHALL continue rendering projectM frames (feeding silence or the last buffer) rather than freezing, and SHALL not crash on empty PCM.

### Preset loading & transitions
- **F9.** The app SHALL bundle the full `~/Music/projectm-presets/` tree (11 category directories plus `! Transition` and top-level files) inside the app bundle as a read-only `Presets/` resource.
- **F10.** On first launch, the app SHALL enumerate the bundled preset tree and build an in-memory playlist (using `projectM-playlist` where practical, or equivalent app-side list).
- **F11.** App SHALL advance presets automatically on a configurable interval (default 30 seconds) unless lock mode is active.
- **F12.** App SHALL perform a crossfade/blend transition between presets using the projectM built-in soft-cut mechanism; transition duration SHALL be configurable (default ~3 seconds).
- **F13.** Presets that fail to load or compile SHALL be skipped silently (with internal log), and the next preset selected, without user-visible error dialogs.

### Remote input
- **F14.** Siri Remote swipe-left SHALL trigger "previous preset"; swipe-right SHALL trigger "next preset".
- **F15.** Siri Remote center click (select button) SHALL toggle preset lock. Lock state SHALL pause the auto-advance timer and force the current preset to remain active.
- **F16.** Siri Remote Menu/Back button SHALL toggle the overlay between visible and hidden states. It SHALL NOT exit the app while the overlay is hidden; if the overlay is already visible, a second press MAY either hide the overlay or allow default tvOS "exit to Home" behavior (decision deferred to architect — see Open Questions).
- **F17.** Play/Pause on Siri Remote SHALL toggle audio playback of the active source.
- **F18.** Remote input SHALL be debounced such that rapid preset navigation does not queue more than one pending preset change.

### Overlay UI
- **F19.** Overlay SHALL display at minimum: current preset name, current audio source (Apple Music / Local File / Idle), current track metadata when available (title, artist, album), and lock state indicator.
- **F20.** Overlay SHALL auto-hide after 5 seconds of inactivity once shown, unless the user explicitly hides it sooner with Menu/Back.
- **F21.** Overlay SHALL be rendered over the GL visual without tearing and SHALL dim the underlying visual by no more than 30% while visible to keep the visualizer legible.
- **F22.** A first-run / idle screen SHALL present a source-selection UI (Apple Music, Local File) with a "Start" action; this is the only modal UI in v1.

### Persistence
- **F23.** App SHALL persist across relaunches (via `UserDefaults`): last audio source mode, last preset lock state, last auto-advance interval, last transition duration.
- **F24.** App SHALL persist the last MusicKit queue item identifier (where permitted by MusicKit) so playback can be resumed; if resume is not permitted or item is unavailable, the app SHALL fall back to the idle/attract state without error.
- **F25.** App SHALL NOT persist or cache any PCM data, user library content, or MusicKit auth tokens beyond what Apple's frameworks manage internally.

### Lifecycle & MusicKit consent
- **F26.** On first launch, the app SHALL request MusicKit authorization via the standard Apple prompt before exposing Apple Music controls; if denied, Apple Music mode SHALL be disabled with a clear explanation and Local File mode SHALL remain available.
- **F27.** On app backgrounding (Home button), the app SHALL pause rendering and audio capture; on foregrounding, it SHALL resume without re-authorizing MusicKit unless tvOS requires it.

---

## 4. Non-Functional Requirements

- **N1. Performance.** Sustained 60fps at 1080p and 4K on Apple TV 4K (2nd gen, A12) and newer, measured over a 2-minute sample across 10 representative presets. Frame-time budget: <= 16.6 ms/frame 95th percentile.
- **N2. Resource budget.** Peak memory <= 512 MB; sustained CPU (user-space) <= 60% of one core on A12; GPU utilization unconstrained but must hold 60fps.
- **N3. Startup time.** Cold launch to first rendered visual frame <= 3 seconds on Apple TV 4K (2nd gen).
- **N4. Audio latency.** PCM-tap-to-visual-reaction latency <= 100 ms end-to-end (perceptually tight).
- **N5. Reliability.** No crash, GL context loss, or audio-engine stall across a 30-minute continuous playback session with auto-preset-advance enabled.
- **N6. Preset robustness.** Bundled preset set SHALL load with <= 5% failure/skip rate on first full-pack sweep.
- **N7. Privacy / telemetry.** No analytics SDKs, no crash reporters (beyond Apple's default TestFlight crash logs via Xcode Organizer), no network calls other than those performed by Apple frameworks (MusicKit). No PII storage.
- **N8. Accessibility.** Overlay text SHALL meet WCAG AA contrast when shown over dimmed visuals; no VoiceOver support required in v1 (personal use).
- **N9. Licensing.** App SHALL comply with projectM's LGPL by linking projectM as a dynamic framework and/or providing relinkable object code per LGPL obligations; bundled preset pack license MUST be compatible with redistribution inside a TestFlight build (user-owned pack; confirm license file in pack root).
- **N10. App Store / TestFlight compliance.** No JIT, no downloadable executable code, no private APIs. The projectm-eval tree-walking interpreter is acceptable. All shaders compiled at runtime from preset text are data, not code, per Apple's precedent.

---

## 5. Out of Scope (v1)

- Metal renderer port (deferred to v2).
- AirPlay receiver functionality (not permitted for third-party tvOS apps).
- tvOS screensaver extension or top-shelf extension (not offered by Apple to third-party apps).
- Live microphone / ambient audio capture on tvOS (no mic API).
- Streaming services other than Apple Music (Spotify, Tidal, YouTube Music).
- Preset editor, preset download/sync, preset favorites/starring, preset search UI.
- Cloud sync of settings.
- Multi-user profiles / per-user state.
- Custom shader uploads from user.
- Audio DSP beyond what projectM internally performs (no user-controlled EQ, beat-detection tweaks, etc.).
- iOS / iPadOS / macOS targets (the Xcode project may be structured to allow future expansion, but v1 ships tvOS only).
- Localization beyond en-US.
- In-app purchases, paid tiers, ads.
- Gesture customization, remapping remote buttons.
- Recording / exporting visuals to video.

---

## 6. Assumptions

- **A1.** Minimum deployment target: **tvOS 17.0** (provides MusicKit `ApplicationMusicPlayer`, modern SwiftUI on tvOS, and stable `AVAudioEngine` behavior).
- **A2.** Build toolchain: **Xcode 15.x or 16.x** on macOS 14+ (current as of 2026-04).
- **A3.** Language: **Swift 5.9+ / Swift 6 where compatible** for app code; **C / C++17** for projectM integration layer (mirrors existing projectM build).
- **A4.** Minimum hardware: **Apple TV 4K (2nd generation, A12, 2021)** and newer. Apple TV HD (A8) and Apple TV 4K (1st gen, A10X) are out of scope — projectM at 60fps is not reliably achievable on A10X and older.
- **A5.** Graphics API: **OpenGL ES 3.0** via the existing `vendor/glad/src/gles2.c` loader, consumed through an `EAGLContext` (deprecated on tvOS but still functional) or via `CAEAGLLayer`. Architect to confirm which surface binding is still viable on tvOS 17+.
- **A6.** The developer's Apple ID is enrolled in the paid Apple Developer Program, has TestFlight access, and the App Store Connect record uses bundle ID prefix `com.joshpointer.projectm-tv`.
- **A7.** The MusicKit entitlement is available and can be enabled for the app's App ID; the user has an active Apple Music subscription on the test device.
- **A8.** The bundled preset pack at `~/Music/projectm-presets/` is owned by the user or is under a license permitting embedding in a personal TestFlight build.
- **A9.** CMake-built `libprojectM` and `libprojectM-playlist` can be produced as static libraries or XCFrameworks for the `appletvos` and `appletvsimulator` SDKs; the existing top-level `CMakeLists.txt` requires an Xcode-toolchain wrapper but does not require source changes to the engine.
- **A10.** No UI test automation is required for TestFlight acceptance; manual smoke test on-device is sufficient for personal use.
- **A11.** Visual reference / "correctness" of a preset rendering is judged by the user eyeballing parity with known Milkdrop behavior on desktop; there is no pixel-level golden-image acceptance test.

---

## 7. Open Questions

- [ ] **Q1.** Does MusicKit `ApplicationMusicPlayer` on tvOS 17+ expose its output through `AVAudioEngine` such that an input tap yields usable PCM, or must we use `MPMusicPlayerController` + the system mixer tap, or a custom `AVPlayer`-driven path for DRM-protected Apple Music content? — Architect to verify on-device; this is the single highest-risk unknown.
- [ ] **Q2.** Does DRM on Apple Music streamed content block PCM tap access entirely on tvOS? If so, the fallback is: tap the `AVAudioEngine` mainMixerNode output only for non-DRM content (local files) and use projectM's built-in beat/audio estimation driven by system now-playing metadata for DRM content. — Architect to spike.
- [ ] **Q3.** Menu button behavior: on tvOS, pressing Menu on the root view exits to the Home screen. Should the overlay intercept Menu and prevent exit while visible, or should Menu always allow exit after one press? (F16) — Defer to architect; tentative: first press shows overlay, second press hides it, third press allows tvOS default exit.
- [ ] **Q4.** Should the auto-advance interval and transition duration be user-configurable in v1 overlay settings, or hard-coded with sensible defaults? — Lean toward hard-coded for v1 simplicity.
- [ ] **Q5.** Is there a need for a "shuffle vs. sequential" preset order mode, or is random-shuffle-without-repeat-until-exhausted acceptable as the only v1 behavior?
- [ ] **Q6.** Should the idle/attract state play silent visuals (projectM fed with synthesized low-level noise or zeros) or show a static title card? — Lean toward silent low-noise visuals so the app "looks alive".
- [ ] **Q7.** How is the projectM library linked into the tvOS app — static library built via CMake external project, or XCFramework produced out-of-band and dropped into `apps/tvos/Frameworks/`? — Architect decision; affects build reproducibility.
- [ ] **Q8.** Does the bundled preset pack include a LICENSE the redistribution of which is unambiguous? (Pack root contains `LICENSE.md` — architect to read and confirm compatibility with embedding.)
- [ ] **Q9.** `EAGLContext` / OpenGL ES is formally deprecated on tvOS. Does the current tvOS 17/18 SDK still compile and ship apps using it, and does App Store Connect still accept such builds for TestFlight? — Architect to verify; if blocked, scope changes materially (Metal becomes v1-required, not v2).
- [ ] **Q10.** Should preset lock survive app relaunch (per F23 persistence) or always reset to "unlocked" on launch? — Lean toward unlocked on launch; lock is a transient gesture.
- [ ] **Q11.** What is the maximum PCM sample count projectM accepts per `projectm_pcm_add_float` call on the target build, and does it match the expected `AVAudioEngine` tap buffer size (typically 1024 or 4096 frames)? — Architect to align buffer sizing; F4/F5 depends on this.
- [ ] **Q12.** Should local-file playback loop the current track by default, advance through a picked folder, or stop at end-of-track? — Lean toward loop-current-track for v1 simplicity.

---

## 8. Acceptance Criteria (v1 "done enough to TestFlight")

A TestFlight build SHALL be considered v1-complete when ALL of the following are true on an Apple TV 4K (2nd gen or newer) running tvOS 17+:

- [ ] **AC1.** App installs from TestFlight and launches to the source-selection screen within 3 seconds.
- [ ] **AC2.** Apple Music mode: the user can browse and start playback of a song from their Apple Music library, and within 1 second the visualizer is reacting to audio with visible low/mid/high frequency response (not static, not random-looking).
- [ ] **AC3.** Local File mode: the user can pick a `.mp3` or `.m4a` via document picker and the visualizer reacts to its audio as in AC2.
- [ ] **AC4.** Siri Remote swipe-left/swipe-right changes preset within 300 ms, with a visible transition (crossfade) between presets.
- [ ] **AC5.** Siri Remote center click toggles preset lock; locked preset does not auto-advance for at least 2 minutes of observation; unlock restores auto-advance.
- [ ] **AC6.** Siri Remote Menu button toggles the overlay; overlay shows current preset name, source, track metadata, and lock indicator; overlay auto-hides after 5 seconds of no input.
- [ ] **AC7.** 60fps sustained (measured via Xcode GPU/Metal HUD or `CADisplayLink` instrumentation) across a 2-minute sample sweep of 10 representative presets on Apple TV 4K (2nd gen).
- [ ] **AC8.** 30-minute continuous playback test (Apple Music source, auto-advance enabled) completes with zero crashes, zero GL context losses, and no audio-engine stalls.
- [ ] **AC9.** The full bundled preset pack enumerates on launch with <= 5% of presets failing to load; failures are silent (no user-visible error).
- [ ] **AC10.** Relaunch restores the last audio source mode and last auto-advance interval (per F23); playback does not auto-resume (user must explicitly start).
- [ ] **AC11.** Privacy audit: no network requests outside Apple frameworks (verified via Charles or Proxyman run for 10 minutes); no third-party SDKs in the linked binary.
- [ ] **AC12.** App passes Xcode "Validate App" and uploads to App Store Connect; TestFlight internal tester (the user) receives and installs the build on their Apple TV.
- [ ] **AC13.** LGPL compliance for projectM: the About/overlay screen OR the app's TestFlight "What to Test" notes contain a projectM attribution and a link to the source; the linked build satisfies LGPL dynamic-linking or relinking obligations.
- [ ] **AC14.** Source tree contains a new `apps/tvos/` directory with a buildable Xcode project or SPM manifest, a `README.md` describing the build steps, and does not modify files outside `apps/tvos/` in ways that break the existing projectM CMake build.
