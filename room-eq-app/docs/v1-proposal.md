# Room EQ App — v1 Proposal (flow, architecture, open questions)

Status: draft for review. No code yet.

---

## 0. Five things that should shape the plan

1. **The phone can't directly measure speaker distances.** Bluetooth adds an unknown, changing
   delay, so a sweep tells us the *shape* of the response but not the absolute arrival time.
   Relative timing works when the signals share one Bluetooth stream (L vs R vs sub played
   back-to-back in one file). For center, surrounds and heights we only hear the receiver's test
   tone. **Proposal:** take distances from a tape measure, or from an optional ARKit "point your
   phone at the speaker" step, rather than from acoustics.
2. **Receiver test tones give a level, not a frequency response.** Onkyo, Yamaha and Denon test
   tones are band-limited noise. From them we can match **levels** reliably, and we can roughly
   check the 500 Hz–2 kHz region. We can't get a full response or EQ those channels from
   acoustic data. v1 should promise level matching for those channels and say so plainly.
3. **The iPhone mic is weakest exactly where room EQ matters most.** EasyEyes (in your folder)
   found ~1.4 dB variation at 1 kHz across 8 profiles of the *same* iPhone 12 Pro, and much more
   at 20–100 Hz. Room modes live at 20–200 Hz. The calibration method below that range will make
   or break the product (see §5).
4. **Bluetooth clock drift.** The receiver's DAC clock and the phone's ADC clock aren't locked,
   so a long sweep gets slightly stretched. Deconvolution handles latency but not drift. Plan:
   put a short "bookend" chirp at each end of the sweep, estimate the drift ratio from them,
   resample, then deconvolve (Farina). Keep sweeps around 6–10 s and average several.
5. **Recommendations must fit each receiver's actual controls.** Yamaha offers a parametric EQ,
   while Onkyo and Denon manual EQ use fixed graphic bands (and on Denon, as far as I know, not
   for the sub). The engine should fit the controls a given receiver really has, not ideal
   filters, then round to its step sizes. The DDSP room-EQ paper in your folder (constrained
   biquad fitting with bounded gain/Q) is a good model; we'd run it offline, once.

---

## 1. Screen-by-screen flow

Tone throughout: short sentences, second person, no jargon unless "Details" is open.
Every screen has one primary action.

### A. First run
| # | Screen | What happens |
|---|--------|--------------|
| A1 | **Welcome** | One calm sentence on what you'll get ("Your room, tuned. About 20 minutes."). Slow ambient color animation. |
| A2 | **What you'll need** | Checklist cards: a quiet 20 minutes, your receiver remote, and *optionally* a tape measure. |
| A3 | **Microphone permission** | A friendly reason first, then the system prompt. If the phone model isn't calibrated, we say so honestly here (levels-only mode or blocked; your call, see §6). |

### B. Your setup (once per room, editable later)
| # | Screen | What happens |
|---|--------|--------------|
| B1 | **Your receiver** | Brand → model picker (Onkyo / Yamaha / Denon). Loads that receiver's profile. |
| B2 | **Your speakers** | A visual layout picker (2.1, 3.1, 5.1, 7.1, 5.1.2, 7.1.4…). Tap speakers on a top-down room drawing to toggle them. Sub count. |
| B3 | **Room correction** | Two big choices: "Keep [Dirac Live / Audyssey / YPAO / AccuEQ] and fine-tune around it" or "Turn it off and follow our plan". Includes a "Not sure?" explainer sheet. |
| B4 | **Distances** *(optional)* | Enter seat-to-speaker distances, or use the AR measuring option. Can be skipped; we then skip distance advice. |

### C. Get ready
| # | Screen | What happens |
|---|--------|--------------|
| C1 | **Connect Bluetooth** | Guided pairing with brand-specific photos. The app watches the audio route and only moves on once output is **A2DP to the receiver** and input is the **built-in mic**. If an HFP route appears, it blocks and explains. |
| C2 | **Receiver checklist** | Brand/model-specific cards, each with an exact menu path and a "Done" tap: select the BT input; listening mode → **Stereo** (no upmixing); turn off loudness and dynamic features (Dynamic EQ / Dynamic Volume / Theater-Dimensional etc.); set room correction per B3. |
| C3 | **Phone placement** | Illustration: phone at ear height, mic pointing the way the calibration assumed (see §6), resting on something rather than held. A live "steadiness" check uses the motion sensors. |
| C4 | **Quiet check** | Records the noise floor. A soft, breathing visualization settles when the room is quiet enough. Names likely culprits ("Something's humming low, maybe a fridge or HVAC?"). |
| C5 | **Volume check** | Plays short pink noise through Bluetooth. A ring fills toward "just right" (target ~75 dB SPL at the seat, with headroom). Prompts for "a bit louder" / "a bit softer". Guards against clipping. |

### D. Measure
| # | Screen | What happens |
|---|--------|--------------|
| D1 | **Main seat — front speakers + sub** | Noise floor snapshot → L sweep → R sweep → sub-range sweep (both channels, so bass management routes it to the sub) → repeat ×N. Each sweep gets a quality check: SNR, clipping, a noise burst during the sweep, drift sanity. Bad sweeps are retried quietly ("A noise snuck in. One more try."). |
| D2 | **Other speakers (test-tone mode)** | "Open Speaker Setup → Levels → Test tone on your receiver." The app listens: it detects each tone burst, matches it to the receiver's known channel order, and logs the level. The user can tap "That was [Center]" to correct a mismatch. |
| D3 | **More seats** | A top-down sofa diagram; place a dot for each extra seat (3–5 recommended). Repeat D1 sweeps only, since levels come from the main seat. A progress constellation fills in. |
| D4 | **Analyzing** | 5–10 s of calm motion while the pipeline runs. |

### E. Results
| # | Screen | What happens |
|---|--------|--------------|
| E1 | **Your room, in a sentence** | A headline plus up to 3 finding cards, color-coded by impact, e.g. "Bass booms around 50 Hz", "Your center is a little quiet", "Your sub and speakers overlap unevenly". Each card shows "What it means" and "How much it'll help". |
| E2 | **Details** *(opt-in toggle)* | Graphs: per-seat and averaged frequency response (smoothing selectable), noise floor overlay with greyed "too quiet to trust" regions, impulse response, decay time (RT60 / EDT by band), channel levels. Export as REW-importable text, which earns credibility with enthusiasts. |
| E3 | **Your fix plan** | An ordered checklist grouped by receiver menu (Levels → Crossover → EQ), with exact menu paths and values in that receiver's steps. Each step has a "Why?" disclosure and a time estimate. Things EQ can't fix (deep nulls) become plain-language placement suggestions instead. |
| E4 | **Check your work** | A quick re-measure at the main seat. Before/after overlay with a satisfying "settle" animation and a plain summary of the improvement. |

### F. Ongoing
Home screen with rooms and history (each "tune" is a snapshot), re-tune, settings, calibration
info for this phone, and a glossary.

Error and edge states with designed screens: Bluetooth dropped mid-sweep, too noisy, clipping,
phone call interruption, wrong listening mode detected (L sweep heard equally in both
channels → probably upmixing), unsupported phone, no receiver profile.

---

## 2. Architecture

A SwiftUI app plus local Swift packages. The DSP is pure Swift + Accelerate with no UI or
AVFoundation, so it unit-tests on macOS/CI against synthetic and recorded fixtures.

```
RoomEQ (app target)
├── Features/            SwiftUI screens per flow section (Setup, Prepare, Measure, Results, Fix, History)
│   └── FlowCoordinator  NavigationStack-driven state machine; resumable sessions
├── Packages/
│   ├── DesignSystem     color tokens, type scale, motion curves, components (cards, rings, checklist, charts)
│   ├── AudioIO          AVAudioSession policy + AVAudioEngine play/record
│   ├── SignalKit        pure DSP (Accelerate/vDSP)
│   ├── Calibration      per-model mic curves, versioning, confidence
│   ├── Analysis         measurements → findings
│   ├── Recommendations  findings → receiver-agnostic intents → per-receiver steps
│   ├── ReceiverKit      receiver profiles + controller protocol (manual now, Wi-Fi later)
│   └── Persistence      SwiftData models; raw audio/IR blobs as files
└── Tools/CalibrationCapture  internal-only target for building calibration curves (§5)
```

### AudioIO
- `AVAudioSession`: `.playAndRecord`, mode `.measurement`, options `[.allowBluetoothA2DP]`
  only. Never `.allowBluetooth` / `.allowBluetoothHFP`, which would allow HFP.
- **Route guard** (`RouteMonitor`): asserts output = `.bluetoothA2DP` and input = `.builtInMic`
  with a **pinned data source and polar pattern** (bottom vs front vs back mic; omni). The
  calibration curve is only valid for that exact choice. Any route change pauses the measurement
  and goes to a recovery screen.
- `MeasurementEngine`: actor-based. Schedules the stimulus on an `AVAudioPlayerNode` and records
  the input tap into a ring buffer with host-time stamps. Never assumes alignment; SignalKit does
  that.
- `ToneListener`: streaming band-energy detector for receiver test tones (onset/offset, level).

### SignalKit (pure functions, heavily tested)
- Exponential sine sweep + inverse filter (Farina), with fade in/out and bookend chirps.
- Drift estimation from the bookends → fractional resampling (vDSP).
- FFT deconvolution → impulse response. Harmonic distortion lands in negative time and is
  windowed out (also available as a THD readout in Details).
- IR windowing, 1/N-octave and psychoacoustic smoothing, power averaging across seats.
- Noise floor spectrum in the same bands → **per-band SNR mask** (e.g. require ≥ 15 dB; tunable).
- Schroeder integration → RT60/EDT per octave band.
- Level estimation for band-limited noise (C-weighted and unweighted).

### Calibration
- `MicCalibration` = { deviceModel identifiers, mic data source, orientation, curve
  (freq → dB, from 10 Hz), sensitivity offset (dB SPL at 1 kHz), uncertainty per band, version }.
- Shipped as bundled JSON; later fetched remotely so curves can update without an app release.
- Applied after deconvolution. Uncertainty feeds into how confident the recommendations sound.

### Analysis → Recommendations
- `Analysis` produces typed findings: `ChannelLevelMismatch`, `RoomMode(peak)`,
  `PositionDependentNull`, `CrossoverGap/Overlap`, `SubMainsPhaseCancellation`, `LongDecay`, etc.
  Each finding carries severity and confidence. Nothing is produced for bands masked by low SNR.
- The `Recommendations` engine works in two stages:
  1. **Intent** (receiver-agnostic): `setLevel(ch, dB)`, `setCrossover(ch, Hz)`,
     `setSubPhase/Distance`, `eqCut(ch, f, gain, Q)`, `placement(advice)`.
  2. **Fit** to the receiver's capability model: graphic vs parametric, band centers, gain range
     and step, Q options, whether the sub is EQ-able, and whether manual EQ is even allowed while
     room correction is on. A constrained optimizer fits the target, then rounds to steps.
- **EQ policy, as hard rules:** cuts only; boosts limited to a small gain for broad, consistent
  dips if you allow that (question below); never treat a null that varies across seats; modal EQ
  only below the Schroeder frequency (~200–300 Hz); above it, broad tonal balance only, from the
  multi-seat average.
- **"Keep room correction" path:** measurements already include the correction, so we only
  suggest what the receiver still lets you change (levels, crossover, sub tuning, target/house
  curve tweaks) and avoid stacking EQ on top of the correction where the brand disallows it.

### ReceiverKit (built for Wi-Fi later)
```swift
protocol ReceiverController {
  var profile: ReceiverProfile { get }        // capabilities + menu paths, data-driven
  func apply(_ changes: [SettingChange]) async throws -> ApplyResult
}
// v1:    ManualGuideController → turns SettingChange into illustrated, ordered user steps
// later: OnkyoEISCPController (eISCP over TCP), YamahaYXCController (HTTP), DenonController (Telnet/HTTP)
```
`ReceiverProfile` is JSON data, not code: brand, model, firmware notes, channel order for test
tones, menu paths, control ranges/steps, EQ type, room-correction system. Adding a model means
adding data. The Recommendations engine only ever emits `SettingChange`, so automatic control is
a new controller, not a rewrite.

### Persistence & privacy
SwiftData: `Room`, `SpeakerLayout`, `TuningSession`, `Seat`, `Measurement` (metadata) + IR/audio
files. Everything stays on the device in v1, with no account.

---

## 3. How the research in your folder feeds in

- **Farina ESS (AES 122):** the core measurement; distortion separation; inverse-filter design.
- **EasyEyes (phone-mic profiles):** a profile library keyed by phone model and traceable to a
  reference mic is exactly your model. Reuse their lessons: turn off all input processing, check
  linearity/clipping before measuring, report uncertainty, reject non-repeatable calibrations.
- **DDSP adaptive room EQ:** a constrained parametric-biquad fit with bounded gain/Q; their
  finding that frequency-domain objectives beat time-domain ones. We use it offline, not adaptively.
- **Handclap RIR estimation:** not v1, but a nice later "quick check without your receiver" mode
  (RT60/decay only).
- **AV-Twin / Acoustivision / RIR prototyping:** later ideas (room visualizations, decay
  analysis UI); no v1 dependency.

---

## 4. Proposed build order

| Milestone | Scope | Exit criteria |
|-----------|-------|---------------|
| **M0 — Spike (1–2 wks)** | Bare app on your TX-RZ50: A2DP + built-in mic + `.measurement`; sweep → IR; drift correction; test-tone capture. | 10 back-to-back sweeps repeat within ±0.5 dB from 100 Hz–10 kHz; route never falls back to HFP; tone channels detected correctly. |
| M1 — Core measure | SignalKit, AudioIO, flow C–D for L/R/sub, Details graphs. | Matches a REW + reference-mic measurement within the agreed tolerance. |
| M2 — Calibration | CalibrationCapture tool + first curves. | Curves for the launch iPhone list. |
| M3 — Recommendations | Analysis + intents + Onkyo profile, then Yamaha and Denon. | Fix plan validated on your room. |
| M4 — Polish & verify | Design system, motion, copy, E4 re-measure, edge-case screens. | TestFlight. |

M0 comes first because it tests the riskiest assumptions (Bluetooth codec behavior, drift, iOS
routing) before any UI investment.

---

## 5. Calibration plan (suggested, so you can push back)

- **Reference:** a measurement mic with its own traceable calibration file.
- **Method above ~200 Hz:** a quasi-anechoic or near-field substitution measurement: reference
  mic and phone in the same spot, the same speaker, swapping one for the other.
- **Below ~200 Hz:** a small sealed **pressure chamber** (or ground-plane / near-field) so the
  room doesn't contaminate the curve. This band matters most, and EasyEyes shows phones are
  least consistent there.
- **Units:** at least 3 phones per model where possible; ship the mean curve plus per-band
  spread as uncertainty.
- **Pin:** mic data source (bottom/front/back), polar pattern, orientation (0° vs 90°),
  `.measurement` mode, and iOS version (re-validate after major iOS releases).

The internal CalibrationCapture tool records both mics, computes the curve, and exports the
JSON the app ships.

---

## 6. What I need from you

**Must-have before M0**
1. **Repo:** this branch lives in a Python bootcamp repo. Do you want a new, dedicated repo for
   the app? (Recommended.)
2. **Your iPhone model(s)**, and access to a Mac with Xcode / your Apple Developer team for
   builds. I can write and unit-test code here but can't run iOS builds in this environment.
3. **Confirm the TX-RZ50 setup:** which room-correction system you run (Dirac Live and/or
   AccuEQ), firmware version, and photos of its on-screen menus: Speaker Setup → Levels,
   Distances, Crossover, Equalizer, Listening Modes, Bluetooth.

**Needed by M2–M3**
4. **Reference mic** make/model, and your calibration setup (anechoic, near-field, ground plane,
   pressure chamber?). Which iPhone models will you calibrate, and how many units each?
5. **Phone orientation:** pointing at the ceiling (90°), or pointing at the front speakers (0°)?
   Calibration and UX copy both depend on this.
6. **Launch receiver models** for Yamaha and Denon (and other Onkyo models), plus manuals or menu
   photos so I can build capability profiles (EQ type, bands, ranges, steps, sub EQ yes/no).
7. **Target curve:** flat, or a "house curve" (a gentle bass lift and treble tilt)? Do you allow
   small broad boosts (e.g. ≤ +3 dB) for consistent shallow dips, or strictly cut-only?
8. **Uncalibrated phones:** block them, or allow a "levels only" mode?
9. **Distances:** OK to skip acoustic distance measurement and use manual entry / AR instead?

**Design & product**
10. App name, any brand work so far (logo, palette, type), and whether you'll have an
    illustrator or motion designer, or want me to build motion natively in SwiftUI.
11. **Minimum iOS version.** I suggest iOS 26 for the current SwiftUI/SwiftData/Observation APIs.
12. Business model (paid, subscription, free + unlock)? This affects whether we need accounts or
    a backend in v1. I'm assuming none.
13. Multiple subs in v1, or a single sub only?
14. Languages at launch.
