# Audio Magician

Measure your room with your iPhone and get a calm, plain-language, step-by-step
plan for your AV receiver. Launch receiver: **Onkyo TX-RZ50**. iOS 26+.

```
AudioMagician/
├── project.yml                     XcodeGen spec → generates AudioMagician.xcodeproj
├── App/                            SwiftUI app (iOS only)
│   ├── Audio/                      AVAudioSession policy, AVAudioEngine play/record, live meter
│   ├── Design/                     Theme, animated aura, SoundOrb, components
│   ├── Model/                      App state, tuning flow, sweep runner, SwiftData, StoreKit unlock
│   ├── Features/                   Onboarding, Home, Tuning flow, Results, AR distance, Lab
│   └── Resources/                  Assets, StoreKit test configuration
├── Packages/AudioMagicianKit/      Platform-neutral engine (unit-tested on macOS CI)
│   ├── SignalKit                   sweeps, deconvolution, drift correction, smoothing, RT60, levels
│   ├── Calibration                 per-iPhone mic curves (none shipped yet → levels-only mode)
│   ├── ReceiverKit                 receiver profiles (JSON), menu paths, manual-guide controller
│   ├── RoomAnalysis                measurements → findings (levels, bass peaks/dips, sub blend, decay)
│   └── Recommendations             findings → cut-only EQ fit + ordered plan + friendly copy
└── docs/
    ├── v1-proposal.md              original flow & architecture proposal
    ├── mvp-scope.md                what's in the MVP, what's waiting for v1.1, and why
    └── xcode-setup.md              getting it onto your iPhone
```

## Quick start (on a Mac)

```bash
brew install xcodegen
cd AudioMagician
xcodegen generate
open AudioMagician.xcodeproj
```

Then pick your team under **Signing & Capabilities**, plug in your iPhone and press Run.
Full walkthrough: [`docs/xcode-setup.md`](docs/xcode-setup.md).

Engine tests run anywhere with Xcode installed:

```bash
cd AudioMagician/Packages/AudioMagicianKit && swift test
```

CI (`.github/workflows/audio-magician.yml`) runs the engine tests and builds the app for the
iOS Simulator on every push.
