# Testing ScreenForge end to end

Two layers: an automated suite that covers code paths (including Metal and a real export),
and a manual checklist for the parts that need a person, real devices, and macOS privacy
approval.

---

## 0. One-time setup

```bash
cd /Users/dawood/Documents/ScreenForge
./scripts/build-app.sh     # ~1 min, produces build/ScreenForge.app
./scripts/run.sh --logs    # launches; logs in build/logs/screenforge.log
```

On first launch, grant **Screen Recording** in
System Settings → Privacy & Security → Screen & System Audio Recording, then **relaunch**
the app (macOS only applies the grant on the next launch in many cases).

Optional permissions are requested when you enable the matching feature:
Microphone, Accessibility (cursor telemetry), Camera, Speech Recognition.

Re-run onboarding at any time:

```bash
./scripts/reset-permissions.sh
./scripts/run.sh --no-build
```

---

## 1. Automated tests (do this first)

```bash
./scripts/test-xcode.sh
```

Expected: `✔ Test run with 79 tests in 18 suites passed` and `** TEST SUCCEEDED **`.

Coverage highlights:

- project/timeline math, trims + speeds, cut-boundary frames
- cursor telemetry, smoothing, click press/ripple, idle hide
- auto-zoom suggestions and overlap avoidance
- transcript cuts (fillers, pauses, sentences, idempotent re-apply)
- caption layout, six rasterized styles, karaoke highlight
- **Metal compositor**: pipelines load, a rendered pixel is checked, texture factories run
- **full export**: 720p H.264 MP4 with zoom + annotation + caption + cursor; audio mux; GIF
- playback composition durations and seeking
- video import, duplicate-name handling, invalid file rejection
- crash-recovery of an orphaned recording session
- **SwiftUI smoke tests**: recorder and editor render offscreen
- **app flow test**: import a movie → open editor → export

Core-only (no Xcode, no permissions):

```bash
swift build && ./scripts/test.sh
```

Expected: `✔ Test run with 74 tests in 16 suites passed`.

---

## 2. Manual smoke test (≈10 minutes)

Use something visually busy on screen (a slide deck, a browser page, a code editor).

1. **Launch** → recorder window appears, no modal alert.
2. **Pick a display** under *Capture source*. Toggle **Microphone**, **System audio**, **Cursor effects** on.
3. **Start recording** (button or ⌘R) → 3-second countdown, then a floating HUD with timer.
4. Move the mouse, click a few times, type; **pause**, wait 3 s, **resume**, click again.
5. **Stop** from the HUD → “Finishing recording…” → the editor opens with the new project.
6. Press **space** (or play) → preview plays; the cursor is re-rendered (not baked in);
   the edit timeline duration is shorter than wall-clock time because the pause is removed.
7. Click **Add zoom** → a zoom appears at the playhead; scrub through it → smooth in/out.
8. Select a zoom → change **Scale** and **Focus**; **Undo** (⌘Z) restores it.
9. **Export** → MP4 → save to Desktop → export finishes and Finder reveals the file.
10. Play the MP4 in QuickTime: audio is audible, zooms match the preview, duration matches.

---

## 3. Full checklist

### Recording

| # | Action | Expected |
|---|---|---|
| R1 | Record a whole display | Video is the full display, correct aspect, 60 fps |
| R2 | Record a single window | Only that window is captured; resizing it does not break the take |
| R3 | Pause → resume → stop | HUD shows paused state; pause is removed from the timeline |
| R4 | Enable camera | PiP overlay visible in preview and export |
| R5 | Disable microphone | Export still contains system audio |
| R6 | Turn off cursor effects | No synthetic cursor, no ripple |
| R7 | Record with system audio playing music | Music audible in the exported file |
| R8 | Stop with the timer at ~10–20 s | Segment rotation is seamless; no gap or frozen frame |

### Editor

| # | Action | Expected |
|---|---|---|
| E1 | Scrub the timeline ruler | Preview follows without lag; no stale frames at cut points |
| E2 | Add several zooms | One zoom per click point; overlap avoided |
| E3 | Magic zoom (wand) | Zooms generated around cursor activity; *Clear generated zooms* removes them |
| E4 | Trim start/end from the scissors menu | Output duration shrinks; generated trims remain undoable |
| E5 | Change zoom focus/scale/easing | Preview updates live |
| E6 | Add a text annotation, edit the text and position | Renders with background pill; delete removes it |
| E7 | Undo/redo repeatedly | 100-step history; no crash |
| E8 | Quit while dirty, reopen the project | Changes were autosaved |
| E9 | Toggle aspect ratio 16:9 → 9:16 | Screen frame reflows; zoom focus still points at the same content |
| E10 | Change background presets, padding, radius, shadow | Immediate visual change in preview |
| E11 | Change cursor theme/size/smoothing | Cursor updates; smoothing has visible effect |
| E12 | Layout: screen-only / split / overlay / camera fullscreen | Frames and transitions match the inspector |
| E13 | Captions tab → Generate transcript (needs Speech permission) | Word count and caption lines appear; preview shows captions |
| E14 | Enable *Remove filler words* / *Compress long pauses* | Timeline shortens; disabling restores it |
| E15 | Switch caption style/position | Preview updates; karaoke highlights the spoken word |

### Export

| # | Action | Expected |
|---|---|---|
| X1 | MP4 1080p 60, HEVC | Playable in QuickTime; correct duration; audio in sync |
| X2 | MP4 720p 30, H.264 | Smaller file; frame rate 30 |
| X3 | 4K export | Correct 3840×2160; slower but completes |
| X4 | Export GIF | Animated GIF, loop, reasonable size |
| X5 | Cancel an export mid-way | Stops, no partial file left in the destination |
| X6 | Export with no audio sources | Silent MP4 that opens everywhere (not a mislabeled MOV) |
| X7 | Hide the app during export | Export continues; progress updates when you return |

### Import, recovery, shortcuts

| # | Action | Expected |
|---|---|---|
| I1 | File → Import Video… (⌘I) with any MP4/MOV | New project opens with that footage; cursor hidden |
| I2 | Import the same file twice | Second project gets a unique name; nothing overwritten |
| I3 | Import a non-video file | Clear error, no half-created project |
| C1 | Start recording, then `kill -9` the app | Relaunch → “Recovered an interrupted recording” and a new project appears |
| K1 | ⌘R record, ⌘1 editor, ⌘0 recorder, ⌘S save, ⌘Z/⇧⌘Z, ⌘E export, ⌘I import | All work from the menu |
| K2 | Close the window and reopen from the Dock | Recorder returns; recent projects still listed |

---

## 4. Where files live

Because the app is sandboxed, everything is inside its container:

```
~/Library/Containers/studio.screenforge.app/Data/Library/Application Support/ScreenForge/Recordings/
├── <name> <date>.sforge/        finished projects (project.json, media/, cursor.jsonl, transcript.json)
└── Sessions/                    in-progress/disposable recording scratch (removed after success)
```

Exports are written wherever you point the save panel (Desktop, Movies, etc.).

Useful commands:

```bash
# live logs
tail -f build/logs/screenforge.log

# system log, filtered
log stream --predicate 'process == "ScreenForge"' --level info

# environment + entitlements + recent errors
./scripts/diagnostics.sh

# inspect a project
cat "…/Recordings/<project>.sforge/project.json"
```

---

## 5. Known limitations (not bugs)

These are documented in [`STATUS.md`](STATUS.md) and are not implemented yet:

- Motion blur and true loupe/3D-tilt rendering.
- Person-segmentation cutout, face tracking, hide-during-silence.
- Voice enhancement/noise reduction and the audio mixer UI.
- Share links, shared projects, iPhone/iPad capture and device mockups.
- Wallpaper pack; image background import UI (image paths in a project render).
- Image and freehand annotations; masked blur/mosaic (current blur is a dim overlay).

Also expected:

- Screen Recording requires a **relaunch** after granting it.
- Cursor telemetry requires **Accessibility**; without it, recordings are still made with
  cursor effects disabled.
- The first camera/speech use triggers a system prompt; denying falls back gracefully.
- Ad-hoc signing: macOS may warn the first time you open the app; `./scripts/run.sh` from
  the same machine avoids Gatekeeper prompts.

---

## 6. Reporting a problem

```bash
./scripts/diagnostics.sh > /tmp/screenforge-diag.txt
```

Include `/tmp/screenforge-diag.txt`, the steps you took, and (if the app crashed) the most
recent `.ips` from `~/Library/Logs/DiagnosticReports/ScreenForge*`.
