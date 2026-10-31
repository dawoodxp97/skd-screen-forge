# ScreenForge — Build & Feature Status

Last verified on macOS 27.2 / Xcode 27.2, arm64, with
`./scripts/test-xcode.sh` (79 app-hosted tests, Metal + SwiftUI included).

## Build and run

```bash
./scripts/build-app.sh     # ad-hoc signed build in build/ScreenForge.app
./scripts/run.sh           # build + launch
./scripts/test-xcode.sh    # full test suite inside the app host
swift build && ./scripts/test.sh   # core-only tests with Command Line Tools
```

If `xcodebuild` reports that it needs Xcode, either run
`sudo xcode-select -s /Applications/Xcode.app` or use the scripts above, which set
`DEVELOPER_DIR` for you.

First launch asks for **Screen Recording**; recording cannot start without it.
Microphone, Accessibility (cursor telemetry), Camera, and Speech Recognition are
requested only when the corresponding feature is enabled.

## Works today (verified)

| Feature | Evidence |
|---|---|
| Record display or single window (60/30 fps, HEVC) | Segmented writer + crash-safe manifest; export/concatenation covered by tests |
| System audio + microphone capture | AAC tracks in segments, mic mixed at export (test asserts audio track) |
| Camera capture + overlay rendering | `CameraRecorder` writes `webcam.mov`; preview uses a synced second player; export composites the camera texture |
| Pause / resume | Segment rotation + cursor rebasing; pauses removed from output time |
| Crash recovery | Orphaned sessions are rebuilt into projects on launch (test) |
| Cursor-free capture, synthetic cursor | Cursor moved/smoothed by One Euro filter; themes, click ripple, idle hide, loop; drawn in preview and export |
| Automatic zooms | Click/dwell/scroll clustering, overlap avoidance, magic wand (tested) |
| Manual zooms, trims, speed regions | Output-time timeline with undo, autosave (tested) |
| Backgrounds, padding, corner radius, shadow | Canvas inspector + compositor |
| Annotations | Text (Core Text), highlight/shape/blur overlays, timing + placement |
| Transcription | On-device `SFSpeechRecognizer`, word timings stored in the bundle |
| Transcript cuts | Filler removal, pause compression, sentence delete, re-apply is idempotent (tested) |
| Burned-in captions | Six styles, three positions, karaoke word highlight; exported pixels differ with captions on (tested) |
| Layouts | Screen-only, camera fullscreen, split, overlay PiP with transitions; cutout falls back to masked camera |
| Import any video | Creates a portable project; full edit + export flow tested |
| Export | MP4 (H.264/HEVC, 720p/1080p/4K, 24/30/60) and GIF; progress + cancel; audio mux (tested) |
| Preview | Edited `AVMutableComposition`; player time equals export time; shared `FrameRenderer` + Metal compositor |

## Implemented but not machine-verifiable here

These need real hardware/permissions and were not exercised in the sandboxed test run:

- Screen/window capture end to end (needs a TCC grant for Screen Recording).
- Microphone/camera capture with a physical device.
- Accessibility cursor telemetry (needs the TCC grant).
- Speech recognition against real audio.
- Very long recordings and 4K60 sustained throughput.

## Known gaps vs. Screen Studio 4.x

These are **not implemented** and are the roadmap's remaining work:

- Motion blur (subframe accumulation) and true loupe zoom rendering; 3D tilt presets are
  stored but the compositor draws them flat.
- Person-segmentation cutout, face tracking, and hide-during-silence.
- Voice enhancement / noise reduction / podcast chain, and the audio mixer UI.
- Sharing (links, shared projects, cloud transcript) and iPhone/iPad capture + mockups.
- Wallpaper pack and background-image import UI (gradients, solids, screen blur, and
  project-relative image paths already render).
- Image/freehand annotations and true masked blur/mosaic.

## Architecture notes

- `ProjectDocument` is `@MainActor` with undo, autosave, cached cursor/caption tracks,
  and an optional Metal compositor.
- `FrameRenderer` is a pure function of (project, output time); preview and export both
  consume its `RenderState`, which is why captions/zooms/cursors match exactly.
- Recording sessions are self-describing directories under
  `Application Support/ScreenForge/Recordings/Sessions/`; finished projects are
  `.sforge` bundles beside them and the session is deleted after a successful build.
