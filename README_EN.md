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
| Visual proximity detection | Apple Vision detects the hand; a single dimension — its size in frame (distance) — decides |
| Single criterion | Alert when the hand is large enough; 3-frame confirmation and hysteresis, no multi-dimension scoring |
| Live camera preview | See the camera feed at the top of the settings panel with the Vision bounding box overlaid; front camera is mirrored and the box flips with it |
| Polished floating card | Dark glass look + purple/cyan gradient + pulsing halo + countdown bar; never steals focus or blocks clicks |
| Popup never dismissed early | Fixed 4.5s display once triggered, even if the hand moves away; hides only when the countdown ends |
| Three sensitivity levels | Conservative / Standard / Sensitive, mapped to different size thresholds |
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

ScreenGuard now has **one decision path**: if a hand is visible and large enough in the frame (close enough), alert.

```
Camera (~30fps)
  → Vision finds a hand, measures its keypoint bounding-box diagonal (span)
  → span ≥ threshold for 3 consecutive frames → alert
  → moving the hand away does NOT dismiss the popup;
    it hides itself after a 4.5s countdown
```

Earlier versions stacked five layers (multi-target tracking, scale-growth gate, velocity extrapolation, pose, danger zone, occlusion prediction, a six-state machine, 20+ parameters). Real-world testing showed that with a monocular camera, "the hand grows in frame" means both reaching for the screen and rubbing your hands together — and the extra signals also scored high on false positives. The complexity never bought accuracy and kept producing patches and bugs. All of it is now deleted: the detector went from ~1400 lines across seven files to ~300 lines in one.

### The only criterion: hand size in frame

`VNDetectHumanHandPoseRequest` finds a hand, then the bounding-box diagonal of its confident keypoints gives `span` (normalized, 0~1.5). With a monocular camera, distance and apparent size are roughly equivalent: **the closer the hand, the larger it appears**.

| Stage | Rule |
| --- | --- |
| Threshold | Conservative `0.62` / Standard `0.48` / Sensitive `0.36`, from the menu |
| Trigger | `span ≥ threshold` for 3 consecutive frames (~100ms at 30fps), to reject single-frame jitter |
| Release | `span ≤ threshold × 0.78` for 3 consecutive frames; hysteresis prevents flapping |
| Cooldown | The "Reminder interval" setting (3/5/8/12s) gates successive alerts |

`confidence` and `handCount` only confirm "a hand was actually seen this frame" and are logged for diagnostics — they never affect scoring. There is no growth, direction, pose, zone, or velocity dimension, and no state machine.

### Popup behavior

Once triggered, the popup stays for **4.5 seconds**, with the progress bar counting down in sync. Moving or removing the hand, or resetting detector state, never dismisses it early — the detector deliberately registers no `dismiss` callback of any kind. Hiding is solely the `OverlayManager` countdown timer's job. This is also the simplest possible fix for the old "stuck on Alerted" bug: there is no state machine left to get stuck in.

### Concurrency & lifecycle

- The capture session and lifecycle state are guarded by a `generation` token plus a lock, preventing stale sessions from reviving via delayed camera-permission callbacks; all UI-state writes in `start` / `stop` are dispatched to the main thread.
- Frame processing, detector reset, and diagnostic caching are all serialized on `analysisQueue`; `stop` / camera switching sets `analysisActive=false` to discard already-enqueued stale frames, eliminating cross-thread data races and "ghost alerts."

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
│   ├── HandProximityDetector.swift        # All detection: capture + single-dimension decision + diagnostics
│   ├── MenuContent.swift                  # Menu bar settings UI
│   ├── OverlayManager.swift               # Floating alert window + card visuals + 4.5s countdown
│   └── DiagnosticCapture.swift            # Diagnostic snapshots (standalone, removable)
└── build/                                 # Build output (git-ignored)
    └── 屏幕守卫.app
```

**External interface**: `HandProximityDetector` communicates with the UI through `@Published` state and an `onTrigger` callback. Everything lives in one file; the decision logic is in one place.

---

## Menu Reference

Click the hand icon in the menu bar:

| Option | Details |
| --- | --- |
| Enable gesture monitoring | Master switch; turning it off stops the camera and clears state |
| Live camera preview | Camera feed above the strength bar, with detection box and hand count; shows a placeholder until monitoring starts |
| Detection strength bar | Live hand size vs. threshold; turns orange/pink near trigger |
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
- JSON fields (`algorithm: single-span-v4`): `span` hand size in frame, `threshold` active threshold, `strength` span/threshold ratio, `handCount` hands detected, `confidence` mean keypoint confidence, `sensitivityLevel`, `latched` decision state. No multi-dimension scoring fields.

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

All decision parameters are in the `Config` enum at the top of `HandProximityDetector.swift` — six constants total:

| Constant | Default | Effect |
| --- | --- | --- |
| `thresholds` | `[0.62, 0.48, 0.36]` | Size threshold per sensitivity level; raise if false positives, lower if missed |
| `releaseFactor` | `0.78` | Hysteresis for release; too low flaps, too high delays release |
| `confirmFrames` | `3` | Consecutive frames for trigger/release; lower is more sensitive but jitterier |
| `frameIntervalNanos` | 33ms | Sampling interval (~30fps) |
| `jointConfidence` | `0.3` | Minimum keypoint confidence |
| `minimumValidJoints` | `6` | Minimum valid keypoints to count as "hand seen" |

The popup's 4.5s duration appears twice — `OverlayManager.present()` and the `AlertCardView` progress animation — and must be changed together.

---

## Known Limitations

**Requires real-device testing:**

- **Camera blind spots**: the MacBook camera sits above the screen facing the user. Hands approaching from the side or below, or already touching the panel, may be invisible — and what the camera can't see can't be predicted. That's physics.
- **Lighting and background**: low light, cluttered backgrounds, and strong backlight reduce Vision keypoint confidence.
- **False positives are inherent to a single dimension**: raising a hand or opening the palm triggers an alert — with one dimension there is no way to tell "held still" from "reaching for the screen." This trade-off is deliberate.
- **Lighting and occlusion**: low light or cluttered backgrounds degrade Vision keypoints; if fewer than the minimum valid keypoints are visible, the frame counts as "no hand."

**Deliberately not implemented (single-dimension by design):**

- Multi-target tracking, scale-growth gate, velocity/direction/pose/zone scoring, occlusion prediction, risk state machine — all removed, not coming back.
- Core ML hand detection, optical flow, Kalman filtering, 3D depth estimation.
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
