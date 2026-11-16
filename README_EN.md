# ScreenGuard

> A vision-based macOS utility: when a hand is detected approaching your screen, an elegant floating card appears and politely asks, "Please don't touch the screen with your finger."
>
> Everything runs locally — no network, no uploads, no third-party dependencies.

![ScreenGuard](Resources/图标预览.png)

---

## Table of Contents

- [The Story](#the-story)
- [Features](#features)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Menu Reference](#menu-reference)
- [Diagnostic Snapshots (removable)](#diagnostic-snapshots-removable)
- [Build & Develop](#build--develop)
- [Known Limitations](#known-limitations)
- [Design Decisions](#design-decisions)
- [License](#license)

---

## The Story

Some people simply can't resist a glowing screen. They have to reach out and poke it — and then shrug, "I just touched it."

Hence ScreenGuard: a tiny guardian living in your menu bar, quietly watching the camera. It doesn't scold, doesn't fire a system notification, doesn't interrupt what you're doing. It just waits until that hand is **actually getting closer** — then gently floats up a card:

> **Please don't touch the screen with your finger**
> Give your fingertips a little space. Let your screen last a little longer.

### A timely rant

The irony is almost too good: while this project was being built (October 2026), Apple released **the first MacBook Pro with a touchscreen** — a PROLED XDR dual-layer OLED panel with ten-point multitouch, starting at CNY 22,999 and reaching about CNY 112,626 fully loaded. The touch sensors are baked right into the display. The marketing says "your fingers and keyboard/mouse, in perfect harmony." Reviewers say "play a piano with ten fingers, spin a 3D model by hand."

What the press releases didn't dwell on: **this screen is a fingerprint magnet.**

An OLED mirror-coating plus a surface you're encouraged to touch constantly equals a laptop that's smeared with oil after a single swipe. MacBook owners used to worry about *other people* touching their screen. Now they worry about *themselves* touching it and having to wipe it down. We've evolved from "preventing others from touching" to "preventing ourselves from leaving fingerprints" — a rather odd branch on the technology tree.

So ScreenGuard's positioning has become slightly delicate: it guards against **someone else's** hand. As for the fingerprints on your own new touch MacBook — sorry, you'll need a microfiber cloth. (If it really bothers you, the source is fully open; PRs for an "auto-wiping robotic arm" module are welcome.)

---

## Features

| Feature | Details |
| --- | --- |
| Visual proximity detection | Apple Vision framework detects hand and upper-body keypoints to judge approach |
| Scale-growth gate | Alerts only when the hand keeps getting *larger* (coming closer); raising or opening a hand won't trigger it |
| Multi-pose / multi-direction | Not tied to a single gesture — palm, arm, and left/right approaches all contribute evidence |
| Polished floating card | Dark glass look + purple/cyan gradient + pulsing halo + countdown bar; never steals focus or blocks clicks |
| Three sensitivity levels | Conservative / Standard / Sensitive, mapped to different risk thresholds |
| Adjustable cooldown | 3 / 5 / 8 / 12 seconds to avoid nagging |
| Camera selection | Auto / built-in / external / Continuity Camera (iPhone) |
| Diagnostic snapshots | Auto-save frame + data on alert for analyzing false positives/negatives (fully removable) |
| Fully local | Frames analyzed in memory; only optional local diagnostic files are written — nothing leaves the Mac |

---

## Quick Start

### Requirements

- macOS 14.0 or later
- A Mac with a camera (built-in, external, or iPhone Continuity Camera)
- Xcode command line tools (`xcode-select --install`)

### Install

```bash
git clone <repository-url>
cd windows/ScreenGuard
chmod +x build.sh
./build.sh
```

This produces `build/屏幕守卫.app`. Double-click to run:

```bash
open -a "build/屏幕守卫.app"
```

### First launch

Grant camera access when prompted. If you accidentally denied it, go to:

> System Settings → Privacy & Security → Camera → enable "屏幕守卫" (ScreenGuard)

The app then lives in your menu bar as a hand icon: `✋` (monitoring) / `🚫` (paused).

> Note: the app is ad-hoc signed with Bundle ID `com.workbuddy.screenguard`. If macOS resets permission after a migration or reinstall, just grant it again.

---

## How It Works

ScreenGuard turns camera frames into an alert decision through a **layered detection pipeline**. This version has been simplified: only signals that actually drive the decision remain; the idle upper-body branch and the noisy velocity score have been removed.

```
┌─────────────────────────────────────────────┐
│ Layer 1  Visual Perception                    │
│  VNDetectHumanHandPoseRequest (up to 2 hands)  │
└──────────────────┬──────────────────────────┘
                   ↓
┌─────────────────────────────────────────────┐
│ Layer 2  Multi-target Tracking                 │
│  Cross-frame nearest-neighbor, velocity-extrapolated │
│  matching, smoothed tracks, 8-frame scale window    │
│  A lost keypoint ≠ a lost target                    │
└──────────────────┬──────────────────────────┘
                   ↓
┌─────────────────────────────────────────────┐
│ Layer 3  Motion & Intent Analysis              │
│  Growth / zone / gesture / direction (velocity diagnostic-only) │
└──────────────────┬──────────────────────────┘
                   ↓
┌─────────────────────────────────────────────┐
│ Layer 4  Occlusion Prediction                  │
│  Short-horizon constant-velocity + acceleration │
│  prediction, exponential confidence decay       │
│  Core principle: hand gone ≠ danger over        │
└──────────────────┬──────────────────────────┘
                   ↓
┌─────────────────────────────────────────────┐
│ Layer 5  Risk Decision — state machine          │
│  Growth-first scoring + hard growth gate         │
│  + cooldown + hysteresis                        │
└─────────────────────────────────────────────┘
```

### The key idea: the scale-growth gate

This is the single most important — and most iterated — rule in the system:

> **Only alert when the hand's bounding box has been continuously growing over multiple frames.**

| Motion | Scale history | Alert? |
| --- | --- | --- |
| Hand moving from far toward the screen | Area grows monotonically across frames | Yes |
| Raising a hand / opening the palm | Area jumps once, then stays flat | No |
| Hand held still in the air | Area barely changes | No |
| Hand moving away from the camera | Negative growth | No |

`HandTrackingEngine.scaleGrowth(for:)` examines the bounding-box area over the last 8 frames: it returns a positive growth score only if the area is more than 6% larger than the first frame, the absolute delta is at least 0.004, and at least 65% of the steps are increases. `RiskEvaluator` then requires growth ≥ 0.22 for 2 consecutive frames before opening the gate. The gate is a **necessary condition** for `alert` — no matter how fast the motion or how gesture-like the pose, without the gate nothing fires. The absolute-delta floor filters out "percentage growth" caused by keypoint jitter.

### Risk scoring

Only discriminative signals are scored (weights sum to 1):

| Feature | Weight | Meaning |
| --- | --- | --- |
| `growth` | 0.62 | Is the hand continuously growing (the core prerequisite, dominant) |
| `zone` | 0.18 | Inside the lower danger zone |
| `gesture` | 0.12 | Pointing / open-hand pose (weak aid) |
| `direction` | 0.08 | Is motion heading toward the screen region (weak aid) |

`velocity` is still computed and written to the diagnostic JSON but **does not affect scoring**: at 30fps, a two-frame keypoint difference amplifies jitter into high speed, which was the main noise source behind false positives. The upper-body extension branch and its weight redistribution have been removed entirely, since the feature is constantly 0 in normal seated use.

**Three signal toggles**: the `Index extended` / `Approaching` / `Danger zone` tags in the menu are clickable switches mapped to `gesture` / `growth + direction` / `zone`. Turning one off zeroes its weight and re-normalizes the remaining enabled weights to sum to 1 — e.g. with `Danger zone` off, the weights become growth ≈0.76 / direction ≈0.10 / gesture ≈0.15. At least one signal must stay on. Note: turning off `Approaching` also disables the hard scale-growth gate, so alerts then rely only on zone and gesture and **false positives will rise noticeably**.

Thresholds by sensitivity: **Conservative 0.62 / Standard 0.48 / Sensitive 0.36**. The confirmation window was tightened from 3 to 2 frames; strong growth inside the danger zone fires in a single frame so quick pokes are not missed.

### State machine

```
idle → observing → approaching → alert → recovery → idle
                 ↘ occluded (optional, not a required stage)
```

- `alert` requires 3 consecutive frames passing both gate and threshold (an extremely strong approach signal counts double, reaching it in two frames ≈ 66ms).
- Once alerted, the card stays until the hand settles for ~0.67s or all occlusion evidence vanishes — preventing a flash-in-the-pan notification.
- Visual confidence and intent confidence are deliberately separate: "seeing clearly" ≠ "intending to touch."

---

## Project Structure

```
ScreenGuard/
├── Package.swift                          # SwiftPM manifest (macOS 14+, no dependencies)
├── build.sh                               # Build + package .app + ad-hoc sign
├── Resources/
│   ├── Info.plist                         # Metadata and permission strings
│   ├── generate_icon.swift                # CoreGraphics 1024px icon source
│   ├── build_icon.sh                      # iconset → AppIcon.icns
│   ├── AppIcon.icns                       # Compiled icon
│   └── 图标预览.png                        # Icon preview (README image)
├── Sources/ScreenGuard/
│   ├── main.swift                         # Entry point, menu bar, lifecycle, debug notifications
│   ├── HandProximityDetector.swift        # Coordinator: orchestrates capture + modules, stable API
│   ├── MenuContent.swift                  # Menu bar settings UI
│   ├── OverlayManager.swift               # Floating alert window + card visuals
│   ├── DiagnosticCapture.swift            # Diagnostic snapshots (standalone, removable)
│   ├── Models/
│   │   └── DetectionModels.swift          # HandTrack / state / assessment / features
│   └── Detection/
│       ├── HandPoseAnalyzer.swift         # Hand keypoints, index extension, palm openness
│       ├── HandTrackingEngine.swift       # Multi-target association, smoothing, scale growth
│       ├── OcclusionPredictor.swift       # Occlusion risk hold / decay
│       ├── ScreenGeometry.swift           # Normalized danger-zone model (calibratable)
│       └── RiskEvaluator.swift            # Weighted scoring + state machine (tunables here)
└── build/                                 # Build output (git-ignored)
    └── 屏幕守卫.app
```

**Stable external interface**: `HandProximityDetector` communicates with the UI through `@Published` state and `onTrigger` / `onClear` callbacks, so the detection engine can be swapped without touching the UI layer.

---

## Menu Reference

Click the hand icon in the menu bar:

| Option | Details |
| --- | --- |
| Enable gesture monitoring | Master switch; turning it off stops the camera and clears state |
| Detection strength bar | Live risk vs. threshold; turns orange/pink near trigger |
| Signal toggles | `Index extended` / `Approaching` / `Danger zone` — uniform mini switches that can be toggled both ways; weights are redistributed among enabled signals |
| Sensitivity | Conservative / Standard / Sensitive |
| Reminder interval | 3 / 5 / 8 / 12 seconds |
| Sound | Toggle the soft Tink on trigger |
| Camera | Auto / built-in / external / Continuity Camera |
| Preview alert | See the popup without using the camera |
| Diagnostic snapshots section | Toggle, record current, open folder, snapshot count |

---

## Diagnostic Snapshots (removable)

A temporary feature built for tuning. On each alert it saves the camera frame plus a data JSON, so a false positive or missed detection can be matched with the evidence the system saw.

- Location: `~/Library/Application Support/ScreenGuard/Diagnostics/`
- Each snapshot = a `PNG` (frame) + a `JSON` (data) with matching names
- Automatic rolling cleanup: **only the latest 10 snapshots are kept**; older ones are removed on the next save — no manual maintenance needed
- **Auto snapshot**: saved on alert, for analyzing false positives
- **Record current**: manual button, for analyzing missed detections (hand touched but no alert)
- JSON includes: algorithm version, risk, threshold, growth/zone/gesture/direction features, velocity (diagnostic only), dual confidences, occlusion retention, gate state, scale history, track details

**To remove entirely**: delete `DiagnosticCapture.swift` and the handful of call sites in `HandProximityDetector`, `MenuContent.swift`, and `main.swift`. Nothing else is affected. With the menu toggle off, nothing is written to disk.

---

## Build & Develop

```bash
cd ScreenGuard
./build.sh
```

The script:

1. `swift build --disable-sandbox -c release` (sandbox disabled for this machine's environment)
2. Creates the `build/屏幕守卫.app` bundle structure
3. Copies the executable, `Info.plist`, and `AppIcon.icns`
4. Runs `codesign --force --deep --sign -` for ad-hoc signing

To regenerate the icon:

```bash
./Resources/build_icon.sh   # macOS only; needs sips / iconutil
```

### Handy debug notifications

```bash
# Preview the alert popup (no camera needed)
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.screenguard.preview"), object: nil, deliverImmediately: true)'

# Manually record one diagnostic snapshot
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.screenguard.snapshot"), object: nil, deliverImmediately: true)'
```

### Tunable parameters

| Parameter | File | Effect |
| --- | --- | --- |
| `growthGate` / `growthFramesNeeded` | `RiskEvaluator.swift` | Gate tightness: raise if false positives, lower if missed detections |
| `weights` | `RiskEvaluator.swift` | Baseline feature weights; menu toggles re-normalize them |
| `signal*Enabled` | `MenuContent.swift` / `DetectionModels.swift` | Persisted keys for the three signal toggles (editable from the menu) |
| Three thresholds | `RiskEvaluator.swift` / `HandProximityDetector.swift` | Sensitivity levels |
| `maxMissedFrames` | `HandTrackingEngine.swift` | Max frames of occlusion prediction |
| `predictionWindow` | `OcclusionPredictor.swift` | Occlusion risk prediction window |
| `dangerZoneTop` | `ScreenGeometry.swift` | Danger-zone position (persisted, calibratable) |
| Sampling interval | `HandProximityDetector.swift` | Currently ~30fps (33ms) |

---

## Known Limitations

**Requires real-device testing:**

- **Camera blind spots**: the MacBook camera sits above the screen facing the user. Hands approaching from the side or below, or already touching the panel, may be invisible — and what the camera can't see can't be predicted. That's physics.
- **Lighting and background**: low light, cluttered backgrounds, and strong backlight reduce Vision keypoint confidence.
- **Velocity noise**: a two-frame keypoint difference is jittery during fast motion. Velocity is now diagnostic-only; if false positives persist, raise `growthGate` rather than restoring velocity weight.

**Deliberately not implemented (to avoid piling on algorithms that obscure the source of false positives):**

- Optical flow tracking (`VNGenerateOpticalFlowRequest` / `VNTrackObjectRequest`)
- Kalman filtering (currently constant velocity + acceleration + exponential decay)
- Visual calibration wizard (`ScreenGeometry` has the model and persistence, but no UI)
- Core ML hand object detection (occlusion fallback)
- True 3D depth estimation (monocular limitation; approximated with 2D normalized coordinates)
- Dedicated tests for lighting robustness, long-run power draw, per-device multi-display placement

**Conclusion of the non-visual research** (for reference): Macs ship no LiDAR; ambient light sensors are slow and easily confused by lighting; acoustic sonar is a research prototype; an external ToF depth sensor (e.g. VL53L5CX) is the most credible alternative, but requires extra hardware.

---

## Design Decisions

- **The dialog never steals focus**: `NSPanel` + `.nonactivatingPanel` + `ignoresMouseEvents`, so games and videos aren't interrupted.
- **Restrained window level**: `.floating` (3), not `.screenSaver`, so it never covers system security UI.
- **Follows the screen under the cursor**: on multi-display setups the card appears where you're actually looking.
- **No layered materials**: the card uses a solid gradient instead of `.ultraThinMaterial` — stacking translucent material on a transparent window renders as a gray box on macOS (learned the hard way).
- **No custom menu-bar corner radius**: the `MenuBarExtra` `.window` panel's corners are system-controlled; drawing your own produces gray edges or square corners. Native is best.

---

## License

A personal learning project — free to use and modify. The rant is all in good fun and is not meant to offend any vendor; the touchscreen-fingerprint observation comes from real usage and public reviews.

> One last word: if you're one of the people whose screen gets poked, may this card say the thing you're too polite to say yourself.
> And if you're the one doing the poking — well, now you know someone's watching.
