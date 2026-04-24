# M1 Decision: GL loader + context probe strategy on tvOS

**Date:** 2026-04-17
**Context:** Plan task T04 — determine whether a custom `load_proc` passed to `projectm_create_with_opengl_load_proc` bypasses `PlatformLibraryNames.hpp`'s dylib-name probe and whether `GLResolver::Initialize` gates on a context-probe that needs a tvOS-specific update.

## Evidence (verbatim from source)

### `GLResolver::Initialize` hard-gates on current context

File: `src/libprojectM/Renderer/Platform/GLResolver.cpp`

```cpp
// Line 367-380 — user_resolver is stored but does NOT short-circuit the rest of Initialize:
    state.m_userResolver = resolver;
    state.m_userData = userData;
    lock.unlock();

#ifndef __EMSCRIPTEN__
    // Find source for gl functions. Emscripten does not have libs.
    OpenNativeLibraries(state);                  // ← opens dylibs by name from kNativeGlNames
    ResolveProviderFunctions(state);             // ← resolves CGLGetCurrentContext on Apple
#endif

    // Try to find a current gl context.
    auto currentContext = ProbeCurrentContext(state);   // ← probes CGL only on Apple

// Line 402-410 — HARD GATE:
    {
        std::string reason;
        if (!HasCurrentContext(currentContext, reason))
        {
            m_loaded = false;
            LOG_ERROR(std::string("[GLResolver] No current GL context present: ") + reason);
            return false;
        }
    }
```

### `ProbeCurrentContext` on Apple has only CGL probe

File: `GLResolver.cpp:920-929`

```cpp
#elif defined(__APPLE__)
    // CGL (macOS native OpenGL)
    result.cglLibOpened = state.m_glLib.IsOpen();
    if (state.m_cglGetCurrentContext != nullptr)
    {
        result.cglAvailable = true;
        result.cglCurrent = state.m_cglGetCurrentContext() != nullptr;
    }
```

EAGL (the tvOS/iOS OpenGL ES context type) has no probe. On tvOS none of `eglCurrent`, `glxCurrent`, `wglCurrent`, `cglCurrent` will be true.

### `PlatformLibraryNames.hpp` hardcodes `OpenGL.framework` on Apple

File: `PlatformLibraryNames.hpp:54-57`

```cpp
constexpr std::array<const char*, 2> kNativeGlNames = {
    "/System/Library/Frameworks/OpenGL.framework/OpenGL",
    nullptr};
```

**`OpenGL.framework` does not exist on tvOS/iOS.** Only `OpenGLES.framework` exists. `state.m_glLib.Open()` silently fails (logged at debug level). Then `state.m_cglGetCurrentContext` never resolves (lookup inside `ResolveProviderFunctions` fails because the lib is not open), so `cglCurrent` stays false, and `HasCurrentContext` returns false.

### User resolver does NOT bypass the context probe

The user's `load_proc` is stored in `state.m_userResolver` but only consulted inside `ResolveProcAddress` (line 1152-1159) as the first step of per-symbol lookup. The initialization gate at line 405 runs **before** any user resolver is given a chance.

`StrictContextGateEnabled` (env var `PROJECTM_GLRESOLVER_STRICT_CONTEXT_GATE=0`) only affects `VerifyBeforeUse` at line 562 — it does not affect the initial `HasCurrentContext` gate.

## Decision

**Option A (user resolver short-circuits probe) is REFUTED.** The probe runs unconditionally.

**Option B is REQUIRED.** Both patches must be applied:

1. **T05 (`PlatformLibraryNames.hpp`)**: add tvOS/iOS branch under `__APPLE__` that uses `OpenGLES.framework/OpenGLES` as `kNativeGlNames` instead of `OpenGL.framework/OpenGL`.

2. **T05b (`GLResolver.cpp`)**: add a tvOS/iOS branch in `ProbeCurrentContext` that treats "user_resolver is set" as proof of a current EAGL context. Reuse the `cglCurrent` slot in `CurrentContextProbe` so that `HasCurrentContext`, `DetectBackend`, and `VerifyBackendIsCurrent` all accept it without further modification. Rationale for the CGL-slot reuse: avoids touching the `Backend` enum in the header (which would ripple through `CurrentContextProbe`, `VerifyBeforeUse`, and logging).

Both patches are guarded by `#if defined(PROJECTM_TVOS) || defined(PROJECTM_IOS)` so desktop behavior is unchanged.

Also need **T03 (`GladLoader.cpp`)**: relax GLES floor from 3.2/3.20 to 3.0/3.00 for tvOS/iOS. EAGL on tvOS caps at GLES 3.0.

## Net upstream footprint

Three guarded edits, total ~20 lines:

| File | Lines | Purpose |
|---|---|---|
| `GladLoader.cpp` | ~8 | Relax GLES version floor |
| `PlatformLibraryNames.hpp` | ~5 | Use OpenGLES.framework path |
| `GLResolver.cpp` | ~8 | Accept EAGL as current context via user_resolver signal |

All additive, all `PROJECTM_TVOS`/`PROJECTM_IOS`-guarded. Desktop, Linux, Windows, Android, Emscripten paths untouched.
