# MVP scope: what ships now, and what waits for v1.1

Decisions locked in: launch receiver **Onkyo TX-RZ50** only · uncalibrated phones get
**levels-only** mode · distances by **hand or camera** · app name **Audio Magician** ·
**iOS 26** minimum · **free with one unlock** (everything except the exact receiver settings) ·
**one subwoofer** · **English** only.

## Works today (MVP)

| Area | What the user gets |
|---|---|
| Onboarding | Welcome, what you'll need, microphone permission |
| Setup | Speaker layout picker (2.1 → 7.1.4, tap to customise), front speaker size, keep or turn off Dirac Live |
| Distances | Manual entry (m or ft), or **camera measurement** using the 17 Pro Max's LiDAR (raycast fallback elsewhere) |
| Connect | Live check that output is **Bluetooth A2DP** and input is the built-in mic; blocks on HFP |
| Receiver checklist | Stereo mode, dynamic features off, room-correction on/off, with RZ50 menu paths |
| Quiet check | Measures the room's background noise; flags low hum |
| Volume check | Plays pink noise; a ring guides the user to the right volume |
| **Speaker levels** (all phones) | Guided test-tone capture for every speaker → level trims rounded to the RZ50's 0.5 dB steps |
| **Distances** (all phones) | Distance settings rounded to the receiver's step size |
| Crossover | Recommendation from speaker size (80 Hz for bookshelf, etc.), snapped to RZ50 options |
| Results | Room score, up to six plain-language finding cards, optional details |
| Fix plan | Ordered steps grouped by menu, each with a "Why?" and menu path. **Settings are locked until unlock; placement and room advice are free** |
| Unlock | StoreKit 2 non-consumable, purchase and restore. Local StoreKit config for testing |
| Check your work | Re-measure and before/after comparison (levels, or bass response when calibrated) |
| History | Rooms and past results saved on the device (SwiftData) |
| Measurement lab | The M0 spike tool: route diagnostics, 1–10 sweeps, repeatability, drift, JSON export |

The full sweep pipeline (sweeps, drift correction, deconvolution, noise-floor gating,
multi-seat averaging, bass peak and dip detection, sub-blend check, RT60, cut-only EQ fitting
to the RZ50's graphic bands) is **built and unit-tested**. It switches on automatically for any
iPhone that has a calibration curve. Until then it's reachable only through the developer toggle.

## Waiting on information from you → v1.1

| Missing information | What's switched off without it | How it plugs in |
|---|---|---|
| **iPhone mic calibration curves** (reference mic, method, units per model) | Frequency response, bass peak/dip findings, EQ, sub-blend check and sub **level** (the iPhone mic rolls off in deep bass, so a sub level reading would be biased). Every phone, including yours, is in levels-only mode | Add curves to `Calibration/Resources/calibrations.json`. Nothing else changes; full mode turns on per device |
| **TX-RZ50 menu photos and confirmation** (menu names, level/distance ranges, EQ bands, whether manual EQ works with Dirac on) | Profile is marked *unverified*; the app shows "menu names may differ slightly" | Edit `ReceiverKit/Resources/onkyo-tx-rz50.json`, set `"verified": true` |
| **Phone orientation for calibration** (ceiling vs speakers) | Placement screen assumes **screen up / mic pointing at the ceiling** (90°) | Change copy in `PlacementView` plus the curve's `orientationDegrees` |
| **Target curve preference** (flat vs house curve, small boosts allowed?) | Flat target, strictly **cut-only** | `TuningPlanner.desiredCuts` |
| **App Store Connect product and price** | Placeholder product `com.audiomagician.app.unlock` at $9.99 in the local test config only | Create the non-consumable in App Store Connect with the same ID |
| **Your M0 lab export** | Thresholds (volume window, quiet threshold, SNR limits) are educated guesses in dBFS | Tune from your real measurements; convert to dB SPL once calibrated |

## Known limitations (by design for v1)

- Center, surrounds and heights are judged on **level only**. Bluetooth is stereo, so their
  frequency response can't be swept.
- Speaker **distances aren't measured acoustically** (Bluetooth latency is unknown). They come from
  the user's tape-measure or camera numbers.
- The crossover suggestion uses speaker size rather than each speaker's measured roll-off.
  Measuring roll-off needs calibration plus a "Full Band" measuring pass (v1.1+).
- Subwoofer phase is a "try it and re-check" step, not a computed value.
- Wi-Fi receiver control isn't built yet. `ReceiverController` is the seam: an Onkyo eISCP
  controller can replace `ManualGuideController` without touching analysis or UI.
