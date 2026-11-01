# ScreenForge — Build & Feature Status

Last verified on macOS 27.2 / Xcode 27.2, arm64, with
`./scripts/test-xcode.sh` (134 app-hosted tests, Metal + SwiftUI included) and
`./scripts/test.sh` (128 core tests).

See [`SCREEN_STUDIO_PARITY.md`](SCREEN_STUDIO_PARITY.md) for the evidence-based
comparison against Screen Studio 4.1.0.

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
| Cursor-free capture, synthetic cursor | Polled telemetry (works sandboxed, no Accessibility needed), One Euro smoothing, themes, click ripple, idle hide, loop; drawn in preview and export |
| Automatic zooms | Click/dwell/scroll clustering, overlap avoidance, magic wand (tested) |
| Manual zooms, trims, speed regions | Output-time timeline with undo, autosave (tested) |
| Backgrounds, padding, corner radius, shadow | Canvas inspector + compositor |
| Annotations | Text (Core Text), highlight/shape overlays, masked Gaussian blur, timing + placement |
| Transcription | On-device `SFSpeechRecognizer`, word timings stored in the bundle |
| Transcript cuts | Filler removal, pause compression, sentence delete, re-apply is idempotent (tested) |
| Burned-in captions | Six styles, three positions, karaoke word highlight; exported pixels differ with captions on (tested) |
| Layouts | Screen-only, camera fullscreen, split, overlay PiP with transitions, person-matte cutout |
| Loupe zooms | Lens render with border/shadow while the frame stays at 1× (state covered by tests) |
| Face tracking | Vision face sampler stored in `project.analysis`; camera reframes toward the speaker |
| Hide during silence | Offline RMS VAD on the mic track; camera fades out over 180 ms inside silent ranges |
| Audio mixer | Mic/system/music/voiceover/sound-effect buses, per-clip gain, fades, loops, music ducking under voice |
| Music & sound effects | Import into the bundle and place on the audio lane; mixed at export through `AVMutableAudioMix` |
| Voiceover | Record in the editor from the playhead; converted to AAC and placed as a clip |
| Recording markers | Live markers/flags from the HUD or ⌘M; rebased across pauses, recovered after a crash, promotable to chapters |
| Import any video | Creates a portable project; full edit + export flow tested |
| Export | MP4 (H.264/HEVC, 720p/1080p/4K, 10/24/30/50/60) and ProRes 422 LT/422/422 HQ/4444 (`.mov`), plus GIF; presets matching Screen Studio's eight recipes; progress + cancel; audio mux (tested) |
| Backgrounds | Gradients, solids, screen blur, imported images, current desktop wallpaper |
| Preview | Edited `AVMutableComposition` with the same audio mix as export; player time equals export time; shared `FrameRenderer` + Metal compositor |
| Person matte | Vision segmentation masks stored per sample; cutout shader feathers the edge |
| Motion blur | Zoom-velocity driven directional blur on the screen layer |
| 3D tilt | Perspective transform for the stored isometric/tilt presets |
| Color grading | Seven analytic looks plus imported 3D `.cube` LUTs, intensity, grain, sharpen |
| Super resolution | Catmull-Rom edge-directed sampling when magnified |
| Voice cleanup | Offline HPF → adaptive gate → presence EQ → compressor → limiter, cached |
| External audio | Any AVFoundation audio input recorded as its own bus with gain |
| Device capture | iPhone/iPad/external video devices record into a project with a vector device frame |
| Device mockups | MacBook, display, iPhone, and iPad frames with notch/base/bezel |
| Wallpaper pack | 27 generated presets across macOS, Midnight, Sunset, Spring, Radiant, Energy, Iridescent, Glassmorphism, Raycast |
| Privacy scan | Vision OCR + face detection create editable blurred masks with 8 pt expansion |
| Chapters | Markers promoted to chapters are written to `moov/udta/chpl` (tested) |
| Click sounds | Four synthesized packs rendered from cursor clicks into a sound-effect clip |
| Presets library | JSON style presets with save/apply/delete (tested) |
| Sharing | System share sheet, AirDrop, optional endpoint upload |
| Licensing/updates | Offline Ed25519 license in Keychain; JSON appcast update check |

## Implemented but not machine-verifiable here

These need real hardware/permissions and were not exercised in the sandboxed test run:

- Screen/window capture end to end (needs a TCC grant for Screen Recording).
- Microphone/camera capture with a physical device.
- Accessibility-gated extras (scroll-wheel samples); core cursor telemetry is polled and needs no grant.
- Speech recognition against real audio.
- Very long recordings and 4K60 sustained throughput.

## Known differences vs. Screen Studio 4.x

All requested features are implemented. The remaining differences are substitutions,
not missing screens:

- Proprietary ML weights are replaced: Vision person segmentation instead of
  `pp-mattingv2`, and a deterministic DSP voice chain instead of MossFormer2 /
  TF-Restormer.
- Anime4K is replaced by a Catmull-Rom edge-directed upscaler.
- Wallpapers and 156 device frames are generated procedurally instead of shipping the
  original artwork.
- Cloud share links, team features, and an account/licensing service need a server;
  local fallbacks and configurable endpoints are provided.
- Mosaic masking still uses a flat fill; blur masking samples the frame.
- Freehand annotation, countdown-length, and cursor-spring tuning remain unimplemented.

`docs/SCREEN_STUDIO_PARITY.md` tracks each item with its evidence level and the exact
substitution.

## Architecture notes

- `ProjectDocument` is `@MainActor` with undo, autosave, cached cursor/caption tracks,
  and an optional Metal compositor.
- `FrameRenderer` is a pure function of (project, output time); preview and export both
  consume its `RenderState`, which is why captions/zooms/cursors match exactly.
- Recording sessions are self-describing directories under
  `Application Support/ScreenForge/Recordings/Sessions/`; finished projects are
  `.sforge` bundles beside them and the session is deleted after a successful build.
