# ScreenForge

A native macOS screen recorder and post-production editor — a from-scratch rebuild of the
Screen Studio 4.x feature set in **Swift 6 + SwiftUI + ScreenCaptureKit + Metal**.

> Working title. Not affiliated with Screen Studio. This project does not copy Screen
> Studio's code or assets; it reimplements the documented product surface with Apple
> frameworks and (for algorithm ideas) the MIT-licensed OpenScreen project.

## Status

`✅` implemented and verified on this machine · `🚧` implemented, needs a full Xcode build to verify
· `📋` designed/modeled only · `⬜` not started

| Area | Status |
|---|---|
| Architecture & roadmap | ✅ [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`ROADMAP.md`](ROADMAP.md) |
| Project model, bundle codec, timeline math | ✅ 30 tests |
| Cursor telemetry, smoothing, click model | ✅ 6 tests |
| Auto-zoom suggestion engine | ✅ 5 tests |
| Transcript cuts (fillers, pauses, sentences) | ✅ 9 tests |
| Caption layout + rasterization (6 styles) | ✅ 6 tests |
| Renderer geometry (layouts, zoom, cursor map, captions) | ✅ 10 tests |
| Document edits (zoom, trim, annotation, undo, autosave) | ✅ 7 tests |
| Capture engine (ScreenCaptureKit, segmented writer) | 🚧 compiles in the core build |
| Metal compositor + shaders | 🚧 shaders need `xcrun metal` (Xcode) |
| Exporter (Metal → AVAssetWriter, audio timeline, GIF) | 🚧 compiles in the core build |
| Editor UI (preview, timeline, inspector, recorder) | 🚧 needs SwiftUI macros from Xcode |
| Speech recognition (word-level, on-device) | 🚧 compiles; needs Xcode build + permission to verify |
| Voice enhancement | 📋 Phase 2 |
| Webcam capture, face tracking, cutout | 📋 Phase 3 (layouts/model done) |
| Sharing | 📋 Phase 5 |

### Verification status

This repository was written on a machine with **only Command Line Tools** installed.
That means:

- The non-UI core (`Model`, `Analysis`, `Capture`, `Media`, document) builds and its 60 tests run
  via SwiftPM — see below.
- The SwiftUI layer and Metal shaders require **full Xcode** (SwiftUI's `@State` macros and
  the `metal` compiler live only there). They are written and syntax-checked, but not yet
  compiled. `scripts/typecheck-app.sh` exists for that step and explains what is missing.

## Requirements

- macOS 14.0+
- **Swift 6.2+ Command Line Tools** — enough for `swift build` and `scripts/test.sh`
- **Xcode 16+** — required to build the app target and compile `Shaders.metal`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & test

```bash
# Core: builds and tests with Command Line Tools only
swift build
./scripts/test.sh                 # 60 tests, Swift Testing

# App: requires Xcode
xcodegen generate
xcodebuild -project ScreenForge.xcodeproj -scheme ScreenForge -destination 'platform=macOS' build
xcodebuild test -project ScreenForge.xcodeproj -scheme ScreenForge -destination 'platform=macOS'

# Type-check the SwiftUI layer without building
./scripts/typecheck-app.sh
```

`Package.swift` exists for the CLT workflow: it compiles the core sources as
`ScreenForgeCore` so model math, analysis, capture, and media code can be tested without
Xcode. The shipping app is still built from the XcodeGen project.

## Permissions

On first launch the app walks through:

1. **Screen Recording** — System Settings → Privacy & Security → Screen & System Audio Recording
2. **Microphone** — voiceover and voice enhancement
3. **Accessibility** — global cursor telemetry (`CGEventTap`)
4. **Camera** — optional, for the webcam layer
5. **Speech Recognition** — optional, for on-device captions

The app is sandboxed with user-selected file access. Recordings default to
`~/Library/Application Support/ScreenForge/Recordings`; exports go wherever the save
panel points.

## Repository layout

```
ScreenForge/
├── App/            lifecycle, menus, app state, document, permissions
├── Capture/        SCStream capture, cursor tap, microphone, session finalizer
├── Analysis/       zoom suggestions, transcript cuts, caption layout/track
├── Model/          project format, bundle store, timeline mapping, cursor telemetry
├── Media/          Metal compositor + shaders, frame renderer, captions, exporter, GIF
├── Editor/         preview (MTKView), playback engine, editor/timeline/inspector views
├── UI/             recorder, source picker, recording HUD, countdown, theme
└── Resources/      asset catalog (app icon slots, accent color)
Tests/              Swift Testing suites (timeline, zooms, cursor, captions, store, renderer)
scripts/            test.sh, typecheck-app.sh
```

## License

MIT for this repository. Screen Studio is a trademark of its owner; this is an
independent, unaffiliated reimplementation.
