# ScreenForge — Production Architecture

> Working name. A native macOS screen recorder and post-production editor targeting full
> feature parity with Screen Studio 4.x (record → edit → share), rebuilt from scratch in
> Swift/SwiftUI with Apple-native capture, rendering, and ML.

---

## 1. What the shipping product actually is (REA findings)

We analyzed the installed Screen Studio 4.1.0 (build 5005) bundle with REA and by
extracting `Contents/Resources/app.asar` (259 MB) with `@electron/asar`.

| Finding | Detail | Implication for us |
|---|---|---|
| Runtime | Electron 41 (`Electron Framework.framework`), arm64-only | It is **not** native Swift today. A native rebuild is a real differentiator (memory, latency, battery). |
| Main process | `dist-electron/index.js` loads a 9.7 MB V8 code cache (`index.arm64.jsc`) via `vm.Script`; `preload.js` is obfuscated (`javascript-obfuscator`) | No usable source; behavior must be inferred from UI + artifacts. |
| Native bridges | `Mantle`, `ReactiveObjC`, `Squirrel` frameworks; deps: `node-mac-permissions`, `node-video-lib`, `wallpaper`, `keytar`, `electron-store`, `electron-dl`, `@sentry/electron` | Capture/permissions/video probing happen in Node/ObjC helpers; licensing via Keychain; auto-update via Squirrel. |
| IPC | `@trpc/client` / `@trpc/server` peer deps | Typed RPC between renderer and main; we mirror this with a typed actor-based service layer. |
| Renderer | 200+ hashed JS chunks, 2.5 MB webp assets | Feature-rich React editor; confirms the editor surface listed on screen.studio. |
| Media stack | `node-video-lib` for probing; `wallpaper` for desktop backgrounds | Export is likely ffmpeg/AVFoundation hybrid; we standardize on AVFoundation + Metal. |

**Takeaway:** parity is a product-surface problem, not a copying problem. We rebuild the
feature set with native primitives, reusing only public knowledge (feature docs) and the
algorithm ideas in the open-source `openscreen` clone (MIT) where useful.

---

## 2. Goals / non-goals

### Goals (v1.0)
1. Record display / window / area at up to 4K60 with system audio + microphone, crash-safe.
2. Record **cursor-free** screen and re-render a synthetic cursor from telemetry (size,
   smoothing, theme, click ripple, idle hide, loop).
3. Automatic + manual zooms (classic + loupe), smart framing that avoids the webcam.
4. Multi-layout camera story: fullscreen camera, split, overlay, screen-only, cutout
   (person segmentation), with animated transitions, face tracking, hide-during-silence.
5. Transcript-based editing: delete a sentence → cut it; filler-word and pause removal.
6. On-device voice enhancement (noise reduction + podcast chain), captions with styles.
7. Backgrounds (wallpapers, gradients, images, Unsplash), padding/shadow/inset, presets.
8. Aspect switching (16:9 / 1:1 / 9:16) with re-aimed zooms, re-arranged layouts, reel
   mode overlays.
9. Annotations/masks (text, arrows, images, blur/mosaic/highlight), motion blur.
10. Export MP4 720p/1080p/4K up to 60 fps, GIF, clipboard copy; shareable links and
    project sharing (cloud, opt-in).
11. iPhone/iPad recording with device mockups over USB.
12. Import any video; projects are portable bundles; presets shareable.

### Non-goals (v1)
- Windows/Linux. (Deliberate: parity with the macOS-only product; revisit in v2.)
- Real-time collaborative editing (shared projects are async hand-off, not co-editing).
- AI voice cloning; only TTS voiceover with system/cloud voices.

---

## 3. Stack

| Layer | Choice | Why |
|---|---|---|
| Language | Swift 6 (strict concurrency), macOS 14+ deployment, macOS 15 APIs gated | ScreenCaptureKit maturity, `SCContentSharingPicker`, on-device Speech. |
| UI | SwiftUI + AppKit interop (`NSViewRepresentable`) for timeline/preview | SwiftUI for chrome; AppKit/Metal for 60 fps surfaces. |
| Capture | ScreenCaptureKit (`SCStream`, `SCContentFilter`, `SCStreamConfiguration`) | System capture, per-window, HDR, low overhead. |
| Cursor | `CGEventTap` (listen-only) + `CGDisplayHideCursor` | Position/click stream independent of capture; enables post effects. |
| Encoding | `AVAssetWriter` (H.264/HEVC, hardware), fragmented segments for crash safety | Hardware media engine, no ffmpeg dependency. |
| Compositing | Metal (`MTLDevice`, compute + render pipelines) | 4K60 with zoom/blur/shadow/masks; preview and export share code. |
| Audio | `AVAudioEngine`, CoreAudio process taps (14.2+), `AVAudioUnitEQ`/Dynamics, RNNoise (optional) | System + mic mix, on-device cleanup. |
| Speech | `SFSpeechRecognizer` (on-device) with word timestamps; `whisper.cpp` fallback | Transcript editing needs word-level timings. |
| Vision | `Vision` face rectangles + person segmentation; `VNGeneratePersonSegmentationRequest` | Face tracking and camera cutout. |
| Persistence | Project bundle (`*.sforge`) with `project.json`, media, `cursor.jsonl`, `transcript.json` | Portable, diffable, crash-recoverable. |
| Networking | `URLSession` + typed API client; signed uploads | Share links, shared projects, optional cloud transcript. |
| Packaging | XcodeGen → Xcode project; `SMAppService` login item; Sparkle or Squirrel-equivalent | Reproducible project, notarized DMG. |
| Telemetry | Opt-in Sentry + `os_signpost` performance | Privacy-first like the original. |

---

## 4. Process & module architecture

```
ScreenForge.app
├── ScreenForge (main app, SwiftUI)
│   ├── App            lifecycle, menus, permissions onboarding, settings
│   ├── Capture        CaptureEngine, CursorRecorder, AudioEngine, RecordingSession
│   ├── Analysis       ZoomSuggestionEngine, TranscriptEngine, FillerWords, FaceTracker
│   ├── Model          Project, Timeline, CursorTelemetry, RenderState
│   ├── Media          Compositor (Metal), FrameRenderer, Exporter, GIF, Thumbnails
│   ├── Editor         EditorView, TimelineView, PreviewView, Inspector panels
│   └── UI             RecorderHUD, SourcePicker, Countdown, Toasts, Theme
├── ScreenForgeCaptureHelper (XPC service, optional hardening)
│   └── SCStream host so a capture crash never kills the editor
└── ScreenForgeShare (app extension, optional)
```

**Concurrency model.** UI is `@MainActor`; capture writes to a serial `DispatchQueue` and
a bounded ring buffer; export runs in a `Task` with back-pressure (`AsyncStream` with
`.bufferingNewest(8)`); all cross-actor payloads are `Sendable` value types. Swift 6 strict
concurrency is enabled from day one.

**Why an XPC helper?** ScreenCaptureKit + AVAssetWriter can abort on GPU/driver faults.
Isolating capture keeps unsaved editor work alive; the helper owns the writer and reports
segment manifests. v1 can ship in-process behind a protocol (`CaptureServicing`) and flip
to XPC without touching the editor.

---

## 5. Recording pipeline

```
 SCContentFilter ──► SCStream (screen, 60fps, BGRA)
                        │  CMSampleBuffer
                        ▼
                 FrameWriter (AVAssetWriter, HEVC)
                        │ every 2s: flush + manifest entry
                        ▼
              recordings/<session>/segments/seg-0001.mov
 CGEventTap ──► CursorRecorder ──► cursor.jsonl (time, x, y, type, click)
 AVAudioEngine ─► mic.wav          system tap ─► system.wav
                        ▼
                 session.json (sources, display scale, permissions, app version)
```

Key decisions:
- **Cursor is never burned into the capture** (`SCStreamConfiguration.showsCursor = false`).
  `CGDisplayHideCursor` during recording for the user's own sanity, restored on stop.
- **Crash safety:** segments of ≤2 s, atomic manifest rewrite, `fsync` on segment close.
  On launch, orphaned sessions are offered for recovery (same guarantee as the original's
  "saved every two seconds").
- **Pause/resume:** close current segment, write a `pause` marker, reopen on resume. The
  timeline treats pauses as removed time; cursor timestamps are rebased.
- **Timestamps:** `CACurrentMediaTime()` for events; sample buffers carry PTS. A session
  clock maps event time → media time, including pause gaps.
- **Display scaling:** store `backingScaleFactor` and content rect so zooms are pixel-exact
  on Retina and external displays.

---

## 6. Project format

`MyDemo.sforge/` (package, `UTType.package`):

```
project.json          # schemaVersion, timeline, layouts, styles, export presets
media/screen.mov      # remuxed/concatenated recording (or segment refs)
media/webcam.mov
media/system.wav
media/mic.wav
cursor.jsonl          # one JSON object per sample (append-only)
transcript.json       # words[], segments[], language, engine
thumbnails/…
```

`project.json` schema (excerpt):

```json
{
  "schemaVersion": 1,
  "id": "UUID",
  "createdAt": "ISO8601",
  "source": { "screen": "media/screen.mov", "webcam": "media/webcam.mov",
              "durationMs": 183400, "width": 3024, "height": 1964, "scale": 2 },
  "canvas": { "aspect": "16:9", "background": { "kind": "gradient", "id": "aurora" },
              "padding": 0.08, "inset": 0, "cornerRadius": 0.02,
              "shadow": { "angle": 90, "distance": 0.03, "blur": 0.06, "opacity": 0.35 } },
  "timeline": {
    "zooms":  [{ "id": "z1", "startMs": 1200, "endMs": 3800, "scale": 1.8,
                 "focus": { "x": 0.42, "y": 0.61 }, "kind": "classic", "easing": "screenStudio" }],
    "trims":  [{ "id": "t1", "startMs": 9000, "endMs": 11250 }],
    "speeds": [{ "id": "s1", "startMs": 12000, "endMs": 20000, "rate": 2.0 }],
    "annotations": [{ "id": "a1", "type": "text", "startMs": 0, "endMs": 3000 }],
    "layouts": [{ "id": "l1", "startMs": 0, "endMs": 6000, "kind": "cameraOverlay" }],
    "captions": { "style": "pill", "wordTimings": "transcript.json" }
  },
  "cursor": { "visible": true, "scale": 1.6, "smoothing": 0.65, "theme": "systemArrow",
              "clickEffect": "ripple", "hideWhenIdleMs": 2500, "loop": false },
  "export": { "resolution": "1080p", "fps": 60, "codec": "hevc", "quality": 0.8 }
}
```

Compatibility rules: unknown keys are preserved (forward-compatible decode), every schema
bump ships a migration, and the app refuses to overwrite a newer `schemaVersion`.

---

## 7. Rendering & compositing

Single source of truth: `RenderState` for time `t` (pure function of project + t).
Preview and export both call `FrameRenderer.render(state:)`; WYSIWYG by construction.

Per frame:
1. Resolve output canvas (aspect, resolution, padding, inset).
2. Compute active layout (screen/webcam frames, cutout mask) with transition easing.
3. Compute zoom transform: union of active zoom regions, cursor-follow focus, contain-scale
   for 3D tilt presets; apply motion-blur accumulation (N subframes, shutter 180°).
4. Composite background (image/gradient/blur-of-screen), shadow, screen texture with
   rounded-corner SDF, webcam layer with mask (rect/circle/rounded/cutout), annotations,
   captions, cursor sprite + click ripple.
5. Metal: one render pass to an `MTLTexture`, then `CVPixelBuffer` for encode or
   `MTKView` for preview. Shaders: `screen.metal`, `background.metal`, `mask.metal`,
   `cursor.metal`, `blur.metal`.

Performance budget (M1 Pro, 4K): ≤ 8 ms/frame preview, ≥ 2× realtime export. Motion blur
and cutout are the expensive passes; both degrade gracefully (half-res mask, 4 subframes).

---

## 8. Audio pipeline

```
mic ──► AVAudioEngine input ──► VoiceEnhancer ──► mix ──► AAC
system ─► CoreAudio tap ──────► (optional music duck) ─┘
```

- **VoiceEnhancer** modes: `standard` (HPF 80 Hz + gentle gate), `noiseReduction`
  (spectral subtraction via Accelerate/vDSP + RNNoise model), `podcast`
  (compressor → EQ presence lift → limiter). All offline, deterministic, previewable.
- Export renders audio offline with `AVAudioEngine.enableManualRenderingMode` so the file
  matches the preview exactly.
- Captions use the **enhanced** mic track for recognition.

---

## 9. Transcript editing & filler removal

1. Transcribe word-level timings (`SFSpeechRecognizer` on-device; `whisper.cpp` fallback
   with `ggml-base.en` for accuracy).
2. Build `TranscriptDocument` (words with `startMs/endMs/confidence`).
3. Editing operations map to timeline cuts:
   - delete range → `TrimRegion` (with 80 ms handles to avoid clipping phonemes)
   - remove filler words → find token matches (`um`, `uh`, `erm`, `like` in filler position)
   - remove long pauses → silence detection on the VAD envelope (≥ 700 ms), speed-up or cut
   - sentence delete → range from first to last word + padding
4. Every operation is undoable and stored as an edit *intent* so re-transcription can be
   reconciled (`TranscriptEdit` list in project.json).

---

## 10. Camera story (layouts, cutout, face tracking)

- `LayoutKind`: `.screenOnly`, `.cameraFullscreen`, `.split`, `.cameraOverlay`,
  `.cameraCutout`. Layout regions are time-ranged; transitions cross-fade/spring between
  normalized frames.
- **Cutout:** `VNGeneratePersonSegmentationRequest` (quality `.accurate`, `outputPixelFormat`
  one-component) at ≤ 1080p, temporally stabilized (mask EMA + feather). Cached per frame
  index for scrubbing.
- **Face tracking:** `VNDetectFaceRectanglesRequest` at 10 Hz, smoothed with a critically
  damped spring; drives crop center. Falls back to center when no face.
- **Hide during silence:** VAD envelope from mic; if RMS < threshold for > 400 ms, animate
  the camera layer out; return with a 150 ms attack. Configurable per layout.

---

## 11. Sharing (optional cloud)

- **Links:** client requests a signed upload URL, PUTs the MP4 (multipart, resumable),
  server transcodes to HLS (1080p60) and returns a slug. Viewer: web player with
  timestamped comments; owner can revoke. 30-minute cap.
- **Shared projects:** zip the `.sforge` bundle (≤20 GB), upload, recipient downloads and
  opens; media paths are relative so it just works.
- **Cloud transcript:** opt-in upload of the enhanced mic track, deleted server-side after
  transcript returns. Never automatic.
- API surface: `POST /v1/uploads`, `POST /v1/links`, `GET /v1/links/:id`,
  `POST /v1/projects`, `POST /v1/transcripts`. Auth: device-code + license entitlement.

---

## 12. Security, privacy, distribution

- Hardened runtime, App Sandbox (user-selected read/write + downloads), notarized DMG.
- TCC: Screen Recording, Microphone, Camera, Accessibility (cursor tap), Speech
  Recognition; onboarding explains each with deep links to System Settings.
- No recording content leaves the device unless a cloud feature is explicitly used; the
  first upload shows a consent sheet. Telemetry opt-out at first launch.
- Secrets in Keychain; licenses signed and verified offline (Ed25519) with a grace period.
- Auto-update: Sparkle 2 with EdDSA signatures, staged rollout, delta updates.

---

## 13. Quality strategy

- **Unit:** timeline math, zoom solver, cursor smoothing, transcript→cuts, project
  migration, export settings (Swift Testing).
- **Golden frames:** render fixture projects at fixed timestamps; compare perceptual hash
  (≤2% delta) across GPU/OS versions.
- **Integration:** record 10 s fixture via SCStream in CI (macOS runner), assert segments,
  audio tracks, crash-recovery manifest.
- **Performance:** XCTest `measure` + `os_signpost` budgets; nightly 4K export benchmark.
- **UI:** XCUITest smoke (record → stop → trim → export), accessibility audit.
- **Beta:** TestFlight for Mac, crash-free sessions ≥ 99.5% gate before launch.

---

## 14. Risks & mitigations

| Risk | Mitigation |
|---|---|
| ScreenCaptureKit quirks per macOS version | Version-gated code paths, capture helper isolation, CI matrix on 14/15/26. |
| 4K60 Metal compositing cost | Half-res masks, tile-based blur, frame skipping in preview only, export at full quality. |
| Person segmentation quality | Accurate request + temporal stabilization; allow manual mask feather; fallback to no-cutout layout. |
| Speech accuracy / languages | On-device Speech first, whisper.cpp fallback; language picker; editable transcript. |
| Cloud scope creep | Ship local-first v1; share links behind a feature flag; projects are files first. |
| 6–12 month solo/small-team schedule | Phase gates in ROADMAP.md; each phase ends with a shippable build. |
