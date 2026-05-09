# projectM tvOS 🎆

> A music visualizer for Apple TV, forked from [projectM](https://github.com/projectM-visualizer/projectm).  
> Formerly **appleJax** + **flapJax**.

## What is this?

A tvOS app that runs Milkdrop-compatible music visualizations on your Apple TV using the [libprojectM](https://github.com/projectM-visualizer/projectm) engine.  
Because tvOS apps cannot access system audio, it pairs with an iPhone companion app (**flapJax**) that streams real-time PCM audio over UDP, or visualizes procedural beats from Apple Music metadata.

## Status

- ✅ M1 — libprojectM tvOS toolchain + upstream patches + build scripts
- ✅ M2-M10 — Full tvOS app scaffold (Xcode project, Swift sources, Metal renderer)
- ✅ QR-pairing + UDP audio streaming from iPhone companion
- ✅ Preset browser with Siri Remote controls
- ✅ GitHub Actions → TestFlight CI/CD

## Quick Start

```bash
# 1. Build the libprojectM xcframework
./apps/appleJax/scripts/build-libprojectm-xcframework.sh

# 2. Sync the preset pack
./apps/appleJax/scripts/sync-preset-pack.sh

# 3. Open apps/appleJax/appleJax.xcodeproj in Xcode
```

## Architecture

```
apps/
├── appleJax/          # tvOS visualizer app (Swift, Metal, UDP receiver)
│   ├── appleJax/      # App source
│   ├── Frameworks/    # libprojectM.xcframework (built)
│   ├── Resources/     # Preset bundles (gitignored)
│   └── scripts/       # Build + sync scripts
└── flapJax/           # iPhone companion app (Expo CNG, Swift module)
    └── modules/flapjax-audio/
```

## Key Features

| Feature | Description |
|---------|-------------|
| **Metal Rendering** | Off-main-thread rendering with resolution scaling |
| **UDP Audio Stream** | Real-time PCM from iPhone mic or local file |
| **Siri Remote** | Full preset browser + overlay navigation |
| **MusicKit** | Procedural beat visualization for Apple Music |
| **TestFlight CI** | Auto-deploy on every push to `main` |

## Upstream Patches

Three guarded patches to libprojectM enable tvOS builds without affecting desktop:

| File | Change | Rationale |
|------|--------|-----------|
| `GladLoader.cpp` | GLES floor 3.0/3.00 | Apple EAGL caps at GLES 3.0 |
| `PlatformLibraryNames.hpp` | `OpenGLES.framework` | tvOS has no `OpenGL.framework` |
| `GLResolver.cpp` | Reuses CGL slot for EAGL | No dlsym-resolvable `CurrentContext` |

## License

- **libprojectM**: LGPL-2.1 (see repo root `COPYING`)
- **This app**: Personal-use only, not published on App Store
- **Presets**: Public-domain-assumed (see `~/Music/projectm-presets/LICENSE.md`)

## Related

- Original projectM: https://projectm-visualizer.github.io/
- Preset pack: https://github.com/projectM-visualizer/presets-cream-of-the-crop
