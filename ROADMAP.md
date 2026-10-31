# ScreenForge — Roadmap to Production

Small team (2–5), 6–12 months. Every phase ends with a **shippable internal build** and a
demo script. Dates assume a start in Q4 2026; compress by cutting Phase 5 cloud work.

> **Implementation snapshot (this repository).** Phases below are the *plan*. The app now
> builds, launches, records, edits, and exports; 79 app-hosted tests pass (Metal, SwiftUI,
> export, playback, import, recovery). Done beyond the original scaffold: live camera
> capture/preview, on-device transcription, burned-in captions, video import, crash
> recovery, GIF, and full export verification. Remaining: motion blur, loupe/tilt
> rendering, cutout/face tracking, voice enhancement + audio mixer, sharing, phone
> capture, and wallpaper/annotation asset packs. See `docs/STATUS.md`.

## Phase 0 — Foundation (weeks 1–4)
**Goal:** record, stop, preview, trim, export a clean MP4.

- [x] Repo scaffold, XcodeGen project, Swift 6 strict concurrency, CI (build + tests).
- [ ] Permission onboarding (screen, mic, accessibility) with status deep links.
- [ ] `SCContentFilter` source picker: display / window / custom area. Window resize presets.
- [ ] `CaptureEngine` → segmented `AVAssetWriter` (HEVC, 4K60), pause/resume, manifest.
- [ ] `CursorRecorder` (`CGEventTap`) → `cursor.jsonl`; hide system cursor while recording.
- [ ] Microphone + system audio (CoreAudio tap) → two WAV tracks.
- [ ] Counting-in overlay, menu-bar HUD, global shortcut, crash recovery prompt.
- [ ] Project bundle model + autosave; editor shell with preview + timeline trim.
- [ ] Export 1080p60 H.264/HEVC with audio mix; progress + cancel.

**Exit:** 5-minute recording survives a force-quit and exports identical audio/video sync.

## Phase 1 — The look (weeks 5–10)
**Goal:** recordings that feel like Screen Studio without any manual editing.

- [ ] Metal compositor: background, padding/inset, corner radius, layered shadow.
- [ ] Backgrounds: 20 wallpapers, gradients, solid, image import, blur-of-screen.
- [ ] Cursor overlay: themes, size, smoothing (Catmull-Rom + spring), click ripple,
      idle hide, loop-to-start.
- [ ] Auto-zoom: click/movement clustering, dwell detection, dead-zone; magic-wand toggle.
- [ ] Manual zoom: drag on timeline, focus handle, depth presets + custom scale.
- [ ] Loupe zoom + 3D tilt presets (iso/left/right) with contain-scale.
- [ ] Motion blur (subframe accumulation), per-zoom easing presets.
- [ ] Speed regions (0.1–16×, pitch-corrected audio), trim regions with waveform.
- [ ] Style presets (save/apply/share as JSON), user preferences.

**Exit:** record a 60 s demo, touch nothing but one button, export looks production-ready.

## Phase 2 — Voice & words (weeks 11–16)
**Goal:** edit by transcript; audio sounds professional.

- [ ] Word-level transcription (Speech on-device; whisper.cpp fallback), language picker.
- [ ] Transcript editor: click word → seek; delete selection → trim; sentence delete.
- [ ] Filler-word removal (`um/uh/erm/like…`) and long-pause compression with undo.
- [ ] Caption rendering: 6 styles, word/line modes, per-caption overrides, auto-sync.
- [ ] VoiceEnhancer: standard / noise reduction / podcast; A/B preview; offline export.
- [ ] Audio mixer UI: mic/system levels, ducking, fade in/out, click track removal.
- [ ] Import external video + audio; relink missing media.

**Exit:** a talking-head tutorial can be cut entirely from the transcript in under 5 minutes.

## Phase 3 — Camera story (weeks 17–22)
**Goal:** multi-layout videos with cutout, tracking, and silence-aware camera.

- [ ] Webcam capture (AVCaptureSession) with device picker, mirror, resolution.
- [ ] Layout regions: screen-only, camera fullscreen, split, overlay, cutout + transitions.
- [ ] Person segmentation cutout (Vision), temporal stabilization, feather, cache.
- [ ] Face tracking crop with spring smoothing; manual override keyframes.
- [ ] Hide-during-silence (VAD) with configurable thresholds.
- [ ] Webcam shapes/masks, shadow, reactive zoom (PiP shrinks as screen zooms).
- [ ] Smart framing: zoom solver avoids covering cursor/face.

**Exit:** one recording can switch screen-only → overlay → fullscreen camera with smooth
animated transitions and a clean cutout.

## Phase 4 — Formats & devices (weeks 23–28)
**Goal:** record once, publish everywhere; phone recordings look native.

- [ ] Aspect switching 16:9 / 1:1 / 9:16 with re-aimed zooms + re-arranged layouts.
- [ ] Reel mode overlays (Instagram/TikTok safe areas), safe-zone warnings.
- [ ] iPhone/iPad USB capture (CoreMediaIO / AVFoundation) + device mockups (bezel/color).
- [ ] Annotations: text (animations), arrows/shapes, images, emoji; z-order + duplicate.
- [ ] Masks: blur, mosaic, highlight/dim, freehand; motion-tracked region option.
- [ ] GIF export (up to 1080p, palette optimization), clipboard copy, export presets.
- [ ] Project templates (e.g. "Product demo", "Course lesson") + onboarding tour.

**Exit:** a single take exports as 16:9 YouTube, 1:1 LinkedIn, and 9:16 Reel with correct
framing and safe areas.

## Phase 5 — Share (weeks 29–34)
**Goal:** stop → link in seconds; collaborate asynchronously.

- [ ] Backend: uploads, HLS transcode, link viewer with timestamped comments, revoke.
- [ ] Share sheet: link, MP4, GIF, clipboard, AirDrop; progress + retry.
- [ ] Shared projects: bundle upload/download, media relink on open.
- [ ] Optional cloud transcript + AI voiceover (explicit consent, deletion policy).
- [ ] Account/licensing: device-code auth, entitlement checks, offline grace.
- [ ] Analytics: opt-in, content-free funnel events.

**Exit:** a link uploaded from the app plays in Safari at 1080p60 on a clean URL.

## Phase 6 — Production hardening (weeks 35–40)
**Goal:** public launch quality.

- [ ] Performance: 4K60 preview on M1, ≥2× realtime export, memory ceiling 1.5 GB.
- [ ] Reliability: fuzz project decode, soak test 2-hour recording, crash-free ≥ 99.5%.
- [ ] Accessibility: VoiceOver labels, keyboard-only editing, reduced motion, contrast.
- [ ] Localization: EN, ES, FR, DE, JA, KO, PT-BR, RU, TR, VI, zh-Hans, zh-Hant, AR.
- [ ] Onboarding, empty states, diagnostics export, safe-mode (disable Metal effects).
- [ ] Notarized DMG, Sparkle auto-update, Homebrew cask, website + docs.
- [ ] Pricing/licensing integration, trial, refund flow; privacy policy + terms.

**Exit:** signed/notarized 1.0, staged rollout, support runbook.

---

## Team allocation (steady state)

| Role | Phase 0–2 | Phase 3–4 | Phase 5–6 |
|---|---|---|---|
| macOS/media engineer | capture, writer, audio | camera, vision | performance, hardening |
| Graphics engineer | Metal compositor, effects | masks, motion blur | GPU optimization |
| Product/UI engineer | editor shell, timeline | annotations, presets | onboarding, a11y, l10n |
| Backend (part-time → full) | — | auth/licensing | share service, billing |
| Design (part-time) | look & feel | mockups, presets | marketing site |

## Milestones / gates

- **M1 (wk 4):** internal alpha — record & export.
- **M2 (wk 10):** private beta — "one-click beautiful".
- **M3 (wk 16):** transcript beta — editing by words.
- **M4 (wk 22):** camera beta — layouts + cutout.
- **M5 (wk 28):** feature-complete local app.
- **M6 (wk 34):** sharing beta.
- **M7 (wk 40):** 1.0 launch.

## Explicitly deferred (post-1.0)

Windows/Linux, real-time collaboration, live streaming, AI b-roll generation, plugin SDK,
team libraries, Windows-native capture parity.
