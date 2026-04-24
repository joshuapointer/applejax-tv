# Critic Review — autopilot-impl.md

**Verdict: REVISE** (5 critical, 6 major, 8 minor findings)

**Confidence (as submitted): 35% → ~75% after critical fixes.**

## Critical issues (must fix before execution)

1. **No task implements persistence (F23, F24, AC10).** No `UserDefaults` wiring for `lastSource`, `lastAutoAdvanceInterval`, `lastTransitionDuration`. AC10 ("Relaunch restores the last audio source mode and last auto-advance interval") cannot be verified. Fix: add dedicated task in M10.

2. **No task implements auto-advance / preset interval (F11, F12).** Plan has no calls to `projectm_set_preset_duration` or `projectm_set_soft_cut_duration`. T38 acceptance ("preset doesn't auto-advance when locked") implicitly assumes auto-advance works. Fix: add these calls in T21 or as a dedicated sub-task.

3. **GLResolver's `Initialize()` will fail on tvOS EAGL — unacknowledged third upstream edit required.** `src/libprojectM/Renderer/Platform/GLResolver.cpp:405-410` calls `HasCurrentContext(probe, reason)` which gates construction. `ProbeCurrentContext` on `__APPLE__` (line 920-929) only detects CGL via `CGLGetCurrentContext` (macOS-only). EAGL has no probe path. Consequence: `projectm_create_with_opengl_load_proc` returns NULL on tvOS regardless of user load_proc. **M4 cannot pass without this fix.** Fix: add guarded `PROJECTM_TVOS`/`PROJECTM_IOS` branch in `GLResolver.cpp`'s Apple `ProbeCurrentContext` that treats EAGL as "has current context" when `PROJECTM_TVOS` is defined.

4. **No task for AC11 privacy audit / N7 telemetry compliance.** Fix: add task running `otool -L` on the built binary + optional Proxyman 10-minute capture to verify no third-party SDKs or non-Apple network traffic.

5. **No task implements F27 (background/foreground lifecycle).** AC8 30-minute stability at risk without `UIApplication.didEnterBackgroundNotification` hooks. Fix: add a task wiring backgrounding to `DisplayLinkDriver.pause` and `AudioController.pause`.

## Major issues (should fix)

1. **T21 drops FBO parameter.** Spec §3.1 says `renderFrame(intoFBO fbo: GLuint) — calls projectm_opengl_render_frame_fbo`. T21 signature is plain `renderFrame()`. `GLKView` rebinds its own FBO (non-zero); plain `render_frame` will render to wrong FBO. Fix: restore `(intoFBO:)` and forward the GLKView-bound FBO.

2. **XcodeGen contradiction — plan commits generated pbxproj while requiring regeneration.** Either gitignore the `.xcodeproj` (standard XcodeGen pattern) and require `xcodegen` as a build prereq, OR drop XcodeGen and hand-author. Fix T51/T43/T09 to one consistent choice.

3. **`AudioController.togglePlayPause()` called in T37 but not defined in T25.** F17 won't compile. Fix: add to `AudioController` (not the protocol) in T25.

4. **T37 implicit dependency on T25 not declared** in `Depends on`.

5. **GLKView deprecation not flagged in R4.** R4 currently names EAGL only. Fix: name both EAGL and GLKView; silence deprecation via `@available`.

6. **Preset pack LICENSE.md is opt-out, not a grant.** T42 must include the text verbatim so any reviewer sees exactly what was assumed. Do not paraphrase.

## Minor issues

1. Spec §2 diagram shows `libprojectM.a`; CMake produces `libprojectM-4.a` (not blocking — xcframework path is consumed).
2. T05 cites line "40–66" for PlatformLibraryNames; actual range is 40-65.
3. T20 invents "memory <200 MB" acceptance not in spec.
4. T08 `clang -x c -E` test won't find `<OpenGLES/ES3/gl.h>` without `-isysroot`.
5. `! Transition` directory has space and leading bang — ensure bash scripts quote properly.
6. T14 acceptance name "Apple TV" — actual simulator name is "Apple TV 4K (3rd generation)".
7. T49 bundled audio fixture for UI test not in T09 XcodeGen spec.
8. T50 execution timing ambiguous — spec says desktop pre-flight; plan says "can run in parallel with M3+".

## Additional gaps

- AC3 ("user picks .mp3 via document picker") is impossible on tvOS (no `UIDocumentPickerViewController`). Plan silently substitutes bundled sample. Needs explicit stakeholder amendment.
- `! Transition` presets are transition helpers, not standalone scenes — `PresetLibrary` should filter them out.
- LGPL-2.1 static-link obligation (object files available for relink) not addressed for TestFlight distribution. For personal TestFlight it's de-minimis, but T42 should document the stance.
- AC8 30-min test and AC7 10-preset sweep are referenced in acceptance but not scripted.

## Coverage matrix highlights

**Missing coverage:** F11, F12, F23, F24, F27, AC10, AC11
**Partial coverage:** F6 (sample-only), F8, F17, F20, F25, AC1, AC3, AC5, AC7, AC8, AC9, AC13

---

End of review.
