# ScreenForge

A native macOS screen recorder and post-production editor — a from-scratch rebuild of the
Screen Studio 4.x workflow in **Swift 6 + SwiftUI + ScreenCaptureKit + Metal**.

> Working title. Not affiliated with Screen Studio. This project does not copy Screen
> Studio's code or assets; it reimplements the documented product surface with Apple
> frameworks and (for algorithm ideas) the MIT-licensed OpenScreen project.

**Current state:** it builds, launches, records (segmented HEVC + system audio + mic +
optional webcam), edits on an output-time timeline, and exports MP4/GIF through the same
Metal compositor used for preview. 134 app-hosted tests pass, including the full
import → edit → export flow. See [`docs/STATUS.md`](docs/STATUS.md) for the feature matrix
and [`docs/SCREEN_STUDIO_PARITY.md`](docs/SCREEN_STUDIO_PARITY.md) for the evidence-based comparison and the remaining gaps.

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
./scripts/run.sh --logs   # build + launch, logging to build/screenforge.log
./scripts/test-xcode.sh   # 134 tests incl. Metal, SwiftUI, export, playback

swift build               # core library, Command Line Tools only
./scripts/test.sh         # core tests, no Xcode required
```

Manual end-to-end checklist, permission reset, and diagnostics:
[`docs/TESTING.md`](docs/TESTING.md) · `./scripts/diagnostics.sh`.

If `xcodebuild` cannot find Xcode, run `sudo xcode-select -s /Applications/Xcode.app`;
the scripts also detect `/Applications/Xcode.app` automatically.

## What is inside

| Layer | Details |
|---|---|
| Capture | `SCStream` 60/30 fps, window or display, system audio, external audio input, microphone, crash-safe 10 s segments, pause/resume, session recovery |
| Device capture | iPhone/iPad/external video devices recorded through AVFoundation with a matching vector device frame |
| Looks | Person-matte cutout, motion blur, 3D tilt, `.cube` LUTs, analytic grades, grain, sharpen, super-resolution, MacBook/iPhone/iPad mockups |
| Privacy | Vision OCR + face detection produce editable blurred masks; person mattes are stored per sample |
| Camera | Separate `webcam.mov`, previewed with a time-synced second player, composited as PiP/split/fullscreen |
| Cursor | `CGEventTap` telemetry, One Euro smoothing, themes, click ripples, idle hide, loop-to-start |
| Audio | Mic/system buses, music and sound-effect clips, voiceover recording, fades, music ducking, silence VAD |
| Markers | Live markers/flags during recording, timeline lane, chapter promotion, crash-safe |
| Editing | Output-time timeline (trims + speed regions), classic + loupe zooms, layouts, markers, annotations, undo/autosave |
| Words | On-device speech recognition, transcript cuts (fillers, pauses, sentences), six caption styles with karaoke highlight |
| Rendering | One `FrameRenderer` → `RenderState`, consumed by both the `MTKView` preview and the exporter |
| Export | Metal frame loop → `AVAssetWriter`; H.264/HEVC/ProRes; mixed and enhanced audio rebuilt on the timeline; eight presets; chapter metadata; GIF via `CGImageDestination` |
| Sharing | System share sheet, AirDrop, optional upload endpoint; offline Ed25519 licensing and JSON appcast update checks |
| Library | 27 generated wallpapers, four click-sound packs, saved project presets, 3D LUT library |
| Projects | Portable `.sforge` bundle: `project.json`, media, masks, `cursor.jsonl`, `transcript.json` |

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
