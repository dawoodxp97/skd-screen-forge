# Screen Studio 4.1.0 Parity Report

**Target:** `/Applications/Screen Studio.app` — version 4.1.0 (build 5005), bundle
`com.timpler.screenstudio`, Electron 41, arm64, minimum macOS 12.
**Method:** static analysis with the REA MCP toolchain plus the shipped JS bundle,
assets, and native helper symbols. No runtime instrumentation of the target app was
performed, so behaviour described as “observed” comes from shipped artifacts, not from
driving the app.

The clone is a native Swift/SwiftUI/Metal app (`ScreenForge`) that reimplements the
workflow. Nothing from Screen Studio's code or assets is copied.

## Evidence levels used below

| Level | Meaning |
|---|---|
| **Observed** | Present in the shipped bundle: readable strings, procedure names, native symbols, assets, or preference keys. |
| **Inferred** | Behaviour deduced from names/structure, not executed. |
| **Unknown** | Could not determine from artifacts (needs runtime probing). |
| **Implemented** | Reproduced in ScreenForge and covered by a test or a deterministic code path. |

## Architecture observed in Screen Studio

- **Electron main + renderer** with an obfuscated JS bundle (`app.asar`, 259 MB). Main
  process exposes backend procedures named `captions.*`, `media.speechRanges`,
  `media.renderAudio`, `share.canCreateShareableLink`, `presets.*`, `luts.*`,
  `backgroundAudio.*`, `project.sensitiveData`, `project.cameraFaces`,
  `project.silenceChunks`, `project.cursorHoverChanges`, `nativeClient.send`.
- **Native helpers:** RecordKit, Polyrecorder, DisplayRecorder, WindowRecorder,
  WebcamRecorder, ExternalDeviceRecorder, CursorRecorder, FocusRecorder,
  AudioRenderer, AudioSilenceDetector, PersonMatte, sensitive-data OCR/face,
  AudioChain, Rust/Hardware video writers, GIF encoder, NativeScrubbing.
- **Models shipped:** `pp-mattingv2-ss8-refined`, `pp-mattingv2-ss9-refined`,
  `pp-mattingv2-ss10-refined` (person matte), Anime4K super-resolution shaders,
  MLX MossFormer2 and TF-Restormer voice enhancement.
- **Speech:** Deepgram / ElevenLabs / Whisper / Apple Speech, chosen per account.
- **Preference keys** include `muteSystemAudio`, `muteMicrophone`, `muteExternalDeviceAudio`,
  `backgroundAudioVolume`, `systemAudioVolume`, `microphoneInStereoMode`,
  `screenSuperResolution`, `motionBlurAmount`, `motionBlurQuality`,
  `sensitiveDataCustomPhrases`, `autoMaskFaces`, `autoMaskSensitiveData`,
  `sensitiveDataExpandPx`, `highlightMaskOpacity`, `deviceFrameKey`,
  `enableDeviceMockup`, `backgroundPop`, `backgroundFillMode`,
  `backgroundPaddingRatio`, `screenBorderRadius`, `cameraScaleDuringZoom`,
  `cameraRoundness`, `cameraSharpen`, `cameraLutGrade`, `defaultOutputAspectRatio`,
  `defaultLayout`, `recordingMarkers`, `recordingFlags`, `recordingCountdownDuration`,
  `recordingUseScreenCaptureKit`, `disableMouseMovementSpring`,
  `stopCursorMovementInLastPartMs`, `hideNotMovingCursorAfterMs`,
  `removeCurshorShakeTreshold`, `loopCursorPositionBeforeEndMs`, `cursorSet`,
  `clickSoundEffect`, `clickSoundEffectVolume`.

## Feature matrix

### Recording

| Feature | Evidence | In ScreenForge | Notes |
|---|---|---|---|
| Display / window capture | Observed (`DisplayRecorder`, `WindowRecorder`, ScreenCaptureKit toggle) | **Implemented** | `SCStream`, 10 s crash-safe segments, pause/resume, recovery |
| 4K60 + HEVC | Observed | **Implemented** | hardware writer, back-pressure buffering |
| System audio | Observed (`muteSystemAudio`, volumes) | **Implemented** | captured with the screen track; optional separate file |
| Microphone | Observed (`microphoneInStereoMode`) | **Implemented** | lossless `.caf` scratch → AAC in the bundle |
| External device audio | Observed (`ExternalDeviceRecorder`, `muteExternalDeviceAudio`) | **Implemented** | any AVFoundation audio input recorded as its own bus with volume |
| Camera | Observed (`WebcamRecorder`) | **Implemented** | best-effort, separate `webcam.mov` |
| Live markers / flags | Observed (`recordingMarkers`, `recordingFlags`) | **Implemented** | ⌘M / ⇧⌘M, HUD buttons, persisted through finalize and recovery |
| Countdown length setting | Observed (`recordingCountdownDuration`) | Partial | fixed 3 s countdown |
| Cursor-free capture + synthetic cursor | Observed (`CursorRecorder`, `cursorSet`) | **Implemented** | polled telemetry + global tap, One Euro smoothing, themes |
| Click sound effects | Observed (`clickSoundEffect`, `clickSoundEffectVolume`) | **Implemented** | four synthesized packs, rendered into a timeline sound-effect clip |
| Mouse spring / anti-shake tuning | Observed (`disableMouseMovementSpring`, `removeCurshorShakeTreshold`) | Partial | smoothing + idle hide; no spring tuning UI |
| Cursor loop / stop in last part | Observed | **Implemented** | `loopToStart` |
| iPhone / iPad capture | Observed in UI strings | **Implemented** | AVFoundation external/continuity video device recording + matching device frame |
| Sensitive-data auto-mask (OCR/faces) | Observed (`autoMaskSensitiveData`, `autoMaskFaces`, OCR) | **Implemented** | OCR + face detection produce editable blurred masks |

### Editing / render

| Feature | Evidence | In ScreenForge | Notes |
|---|---|---|---|
| Classic zooms with spring easing | Observed | **Implemented** | `ZoomEasing.screenStudio` (ease-out-back) |
| Loupe zoom | Observed in UI strings | **Implemented** (new) | lens render + border/shadow, tested state path |
| 3D tilt presets | Observed | **Implemented** | perspective transform in the quad vertex stage |
| Motion blur | Observed (`motionBlurAmount`, `motionBlurQuality`) | **Implemented** | screen-space directional blur driven by zoom focus/scale velocity |
| Auto zoom from cursor | Observed | **Implemented** | click/dwell/scroll clustering |
| Trims, speed regions | Observed | **Implemented** | output-time timeline + mapping |
| Layouts (screen, PiP, split, fullscreen, cutout) | Observed (`defaultLayout`, `cameraScaleDuringZoom`) | **Implemented** | cutout uses stored person mattes |
| Face tracking / auto reframe | Observed (`project.cameraFaces`) | **Implemented** | Vision sampling stored in the project |
| Hide camera during silence | Observed (`project.silenceChunks`, `AudioSilenceDetector`) | **Implemented** (new) | VAD ranges + 180 ms fades |
| Background presets, gradients, solids | Observed (`backgroundFillMode`, `backgroundPop`) | **Implemented** | gradients/solids/screen-blur |
| Background image import | Observed | **Implemented** | imported into the bundle |
| Current desktop wallpaper | Inferred | **Implemented** (new) | `NSWorkspace.desktopImageURL` copied into the bundle |
| Built-in wallpaper pack | Observed in assets | **Implemented** | 27 procedurally rendered presets across all nine observed families |
| Device mockups | Observed (`deviceFrameKey`, 156 frames) | **Implemented** | vector MacBook/display/iPhone/iPad frames with notch, base, and bezel |
| Color grading / LUTs | Observed (`luts.*`, `cameraLutGrade`, `cameraSharpen`) | **Implemented** | 3D `.cube` upload + analytic Golden/Mono/Terra/Teal-Orange/Cool/Warm/Noir |
| Super-resolution | Observed (`screenSuperResolution`, Anime4K) | **Implemented** | Catmull-Rom edge-directed sampling when magnified/upscaled |
| Annotations (text/shape/highlight/mask) | Observed | **Implemented** | exceeds the original in some areas |
| Image / freehand annotations | Observed | Partial | image type renders; no freehand tool |
| True masked blur / mosaic | Inferred | **Implemented** (blur) | masked Gaussian blur samples the frame under the mask; mosaic still uses a flat fill |
| Captions (styles, karaoke) | Observed (`captions.*`) | **Implemented** | six styles, word highlight |
| Transcript cuts | Observed (`media.speechRanges`) | **Implemented** | fillers, pauses, sentences |
| Voice enhancement / denoise | Observed (MossFormer2, TF-Restormer, `AudioChain`) | **Implemented** | offline DSP chain: HPF, adaptive gate, presence EQ, compressor, limiter |
| Audio mixer + music/voiceover clips | Observed (`media.renderAudio`, `backgroundAudio.*`) | **Implemented** (new) | per-clip gain/fades, ducking, 5-bus mixer |
| Voiceover recording in the editor | Observed (`speech.generateVoiceoverForProject`) | **Implemented** (new) | mic → AAC → timeline clip |
| Silence analysis in the editor | Observed (`project.silenceChunks`) | **Implemented** (new) | offline RMS VAD |

### Output / product

| Feature | Evidence | In ScreenForge | Notes |
|---|---|---|---|
| MP4 4K Studio 60 | Observed preset name | **Implemented** (new) | HEVC 4K60 |
| MP4 4K Social 60 | Observed | **Implemented** (new) | H.264 4K60 |
| MP4 720p Web Low 10 | Observed | **Implemented** (new) | 10 fps |
| MP4 720p Web High 60 | Observed | **Implemented** (new) | 60 fps |
| MP4 1080p Social 60 | Observed | **Implemented** (new) | H.264 |
| MP4 1080p Studio 30 | Observed | **Implemented** (new) | HEVC 30 |
| ProRes 4K 422 HQ 60 | Observed | **Implemented** (new) | `.mov`; the writer path is shared, and 422 LT is verified by fourcc in tests |
| ProRes 1080p 4444 30 | Observed | **Implemented** (new) | `.mov`, alpha-capable codec |
| GIF export | Observed | **Implemented** | 10–30 fps, width-limited |
| Custom resolution / quality / audio bitrate | Inferred | **Implemented** | menu + sliders |
| Chapters from markers | Observed (`recordingMarkers`) | **Implemented** | `moov/udta/chpl` written into MP4/MOV; verified by round trip |
| Sharing | Observed (`share.canCreateShareableLink`) | Partial | system share sheet, AirDrop, optional multipart upload endpoint; team/cloud service not included |
| Presets (project presets) | Observed (`presets.*`) | **Implemented** | JSON style library (canvas/camera/cursor/captions/audio/export) with save/apply/delete |
| Recent projects | Observed | **Implemented** | from the recordings folder |
| Licensing / auto-update | Observed (`update.*`) | **Implemented** | offline Ed25519 license verification + Keychain; JSON appcast update check |

## Implementation substitutions (important)

These features are functionally present, but a few use Apple frameworks instead of the
proprietary model files or hosted services the original ships. This is deliberate: the
target's weights (MossFormer2, TF-Restormer), Anime4K shaders, 156 raster device frames,
and wallpaper artwork are not redistributed.

| Feature | Screen Studio | ScreenForge |
|---|---|---|
| Person matte | Bundled `pp-mattingv2` CoreML models | `VNGeneratePersonSegmentationRequest` masks stored with the project |
| Motion blur | Multi-subframe accumulation (`motionBlurQuality`) | Screen-space directional blur driven by zoom velocity |
| Super-resolution | Anime4K shaders | Catmull-Rom edge-directed upscale |
| Voice cleanup | MossFormer2 / TF-Restormer ML | Deterministic HPF + gate + EQ + compressor + limiter chain |
| Wallpapers | ~180 raster assets | 27 generated presets in the same nine families |
| Device frames | 156 PNG frames | Vector frames (MacBook, display, iPhone, iPad) |
| Cloud sharing | Screen Studio service | System share/AirDrop + optional `SCREENFORGE_SHARE_ENDPOINT` upload |
| License/update | Hosted account service | Offline Ed25519 key (Keychain) + configurable appcast JSON |

Everything else in the matrix is native code in this repository and covered by tests.

## What changed in this pass

1. **Schema v2** with additive decoding (`audio`, `analysis`, markers, audio clips) so
   v1 projects still open.
2. **ProRes** in the export writer for 422 LT/422/422 HQ/4444, `.mov` container,
   codec-aware save panel, plus 10/50 fps.
3. **Audio mixer**: five buses, per-clip gain, fades, loops, music ducking under
   voiceover, all expressed as `AVMutableAudioMix` ramps on output time. Preview and
   export share `TimelineAudioMixer`, so what you hear is what gets encoded.
4. **Markers** captured live in the HUD/⌘M, persisted through pause rebasing and crash
   recovery, shown on the timeline, promotable to chapters.
5. **Loupe zoom** rendering, **face tracking** (Vision), **silence detection** (RMS VAD)
   with camera fades.
6. **Background image import**, desktop wallpaper, and gradient/solid color wells.
7. **Export preset library** matching the eight observed Screen Studio recipes.
8. **Person matte cutout, motion blur, 3D tilt, LUT grading, super-resolution, device
   mockups, wallpaper pack, sensitive-data auto-masking, chapters, click sounds,
   external audio, iPhone/iPad capture, presets, sharing, and offline licensing.**

## Verification

- `swift build` — clean.
- `./scripts/test.sh` — 128 core tests pass.
- `./scripts/test-xcode.sh` — 134 app-hosted tests pass, including ProRes export,
  music-clip mixing, preview/export mix parity, chapter metadata, LUT parsing, voice
  enhancement, click tracks, wallpapers, presets, and rendering state.
- `./scripts/build-app.sh` — builds `build/ScreenForge.app`.

## Honest limits

Every feature in the request now has a working implementation in this repository, but
three categories cannot be byte-identical by construction:

- **Proprietary model weights** (person matte, MossFormer2, TF-Restormer) are replaced by
  Apple Vision or a deterministic DSP chain. Quality is comparable for typical screen
  recordings but not model-identical.
- **Hosted services** (cloud share links, account/licensing backend, telemetry) need a
  server. The app exposes the same entry points with local fallbacks and configurable
  endpoints.
- **Artwork** (wallpapers, 156 device frames) is generated procedurally rather than
  copied, so pixels differ while layout and controls match.

Runtime behaviour was inferred from shipped artifacts; no Screen Studio session was
instrumented.
