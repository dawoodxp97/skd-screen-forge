# ScreenForge

A native macOS screen recorder and post-production editor — a from-scratch rebuild of the
Screen Studio 4.x workflow in **Swift 6 + SwiftUI + ScreenCaptureKit + Metal**.

> Working title. Not affiliated with Screen Studio. This project does not copy Screen
> Studio's code or assets; it reimplements the documented product surface with Apple
> frameworks and (for algorithm ideas) the MIT-licensed OpenScreen project.

**Current state:** it builds, launches, records (segmented HEVC + system audio + mic +
optional webcam), edits on an output-time timeline, and exports MP4/GIF through the same
Metal compositor used for preview. 79 app-hosted tests pass, including the full
import → edit → export flow. See [`docs/STATUS.md`](docs/STATUS.md) for the feature matrix
and the remaining parity gaps.

## Quick start

```bash
brew install xcodegen           # if needed
./scripts/run.sh                # builds build/ScreenForge.app and launches it
```

Grant Screen Recording when prompted. Recordings land in
`~/Library/Application Support/ScreenForge/Recordings` (inside the app's sandbox
container) and open in the editor automatically when you stop.

Prefer to try the editor without capturing? **File → Import Video… (⌘I)** turns any
movie into a project.

## Build, run, test

```bash
./scripts/build-app.sh    # ad-hoc signed app in build/ScreenForge.app
./scripts/run.sh          # build + launch
./scripts/test-xcode.sh   # 79 tests incl. Metal, SwiftUI, export, playback

swift build               # core library, Command Line Tools only
./scripts/test.sh         # core tests, no Xcode required
```

If `xcodebuild` cannot find Xcode, run `sudo xcode-select -s /Applications/Xcode.app`;
the scripts also detect `/Applications/Xcode.app` automatically.

## What is inside

| Layer | Details |
|---|---|
| Capture | `SCStream` 60/30 fps, window or display, system audio, crash-safe 10 s segments, pause/resume, session recovery |
| Camera | Separate `webcam.mov`, previewed with a time-synced second player, composited as PiP/split/fullscreen |
| Cursor | `CGEventTap` telemetry, One Euro smoothing, themes, click ripples, idle hide, loop-to-start |
| Editing | Output-time timeline (trims + speed regions), zooms with Studio easing, layouts, annotations, undo/autosave |
| Words | On-device speech recognition, transcript cuts (fillers, pauses, sentences), six caption styles with karaoke highlight |
| Rendering | One `FrameRenderer` → `RenderState`, consumed by both the `MTKView` preview and the exporter |
| Export | Metal frame loop → `AVAssetWriter`; audio rebuilt on the timeline and muxed; GIF via `CGImageDestination` |
| Projects | Portable `.sforge` bundle: `project.json`, media, `cursor.jsonl`, `transcript.json` |

## Permissions

1. **Screen Recording** — System Settings → Privacy & Security → Screen & System Audio Recording
2. **Microphone** — voiceover
3. **Accessibility** — global cursor telemetry
4. **Camera** — optional webcam layer
5. **Speech Recognition** — optional on-device captions

The app is sandboxed (microphone, camera, speech, user-selected files) and ad-hoc signed
for development.

## Repository layout

```
ScreenForge/
├── App/            lifecycle, menus, app state, project document
├── Capture/        SCStream capture, segmented writer, cursor tap, mic, camera, recovery
├── Analysis/       zoom suggestions, transcript cuts, caption layout, speech, import
├── Model/          project format, bundle store, timeline mapping, cursor telemetry
├── Media/          Metal compositor + shaders, frame renderer, captions, exporter, GIF
├── Editor/         preview (MTKView), playback engine, editor/timeline/inspector views
├── UI/             recorder, source picker, recording HUD, countdown, theme
└── Resources/      asset catalog
Tests/              79 Swift Testing cases (timeline, zooms, captions, renderer, Metal, export, import, recovery, UI)
scripts/            build-app.sh, run.sh, test-xcode.sh, test.sh, typecheck-app.sh
docs/STATUS.md      verified features, hardware-dependent items, known gaps
```

## License

MIT for this repository. Screen Studio is a trademark of its owner; this is an
independent, unaffiliated reimplementation.
