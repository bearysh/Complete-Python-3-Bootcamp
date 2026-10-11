# Getting Audio Magician onto your iPhone 17 Pro Max

My session runs in a cloud container (Linux), so it can't run Xcode or reach your
iPhone. There are two ways to close that loop. You'll want both.

## 1. What already works without you: CI on macOS

Every push runs `.github/workflows/audio-magician.yml` on GitHub's macOS 26 runners
(Xcode 26.x). That job:

- runs all engine unit tests (`swift test`), including a full simulated measurement
  (stereo sweeps → two speakers → Bluetooth latency + clock drift → noise → analysis), and
- builds the whole app for the iOS Simulator.

I read those results myself, so most compile errors and logic regressions get fixed
without you lifting a finger. What CI **can't** do is talk to a real microphone,
Bluetooth or your receiver. That needs your Mac and your phone.

## 2. One-time Mac setup (about 30 minutes)

1. **Install Xcode 26** from the Mac App Store and open it once so it installs its components.
2. **Sign in with your Apple ID**: Xcode › Settings › Accounts › `+` › Apple ID.
   - A free account can run the app on your own phone (re-sign every 7 days).
   - For TestFlight, the App Store and the in-app unlock, enrol in the
     [Apple Developer Program](https://developer.apple.com/programs/) ($99/year).
3. **Install Homebrew and XcodeGen** (Terminal):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install xcodegen
   ```
4. **Get the code**:
   ```bash
   git clone https://github.com/<you>/audio-magician.git    # once the new repo exists (see below)
   cd audio-magician/AudioMagician
   xcodegen generate
   open AudioMagician.xcodeproj
   ```
5. **Signing**: select the *AudioMagician* target › *Signing & Capabilities* › tick
   *Automatically manage signing* › choose your Team. If `com.audiomagician.app` is taken,
   change the bundle ID to something like `com.<yourname>.audiomagician` (and the product ID
   in `UnlockStore.swift` / `AudioMagician.storekit` to match).
6. **Your iPhone**: connect it by cable, unlock it and tap *Trust*. Then turn on
   **Settings › Privacy & Security › Developer Mode** and restart when asked.
7. Pick your iPhone as the run destination and press **⌘R**. The first launch may ask you
   to trust the developer: **Settings › General › VPN & Device Management**.

## 3. Let me drive builds on your Mac (recommended)

Run Claude Code on the Mac itself so it can build, run and read device logs directly:

```bash
# on the Mac, inside the repo
curl -fsSL https://claude.ai/install.sh | bash   # or: npm install -g @anthropic-ai/claude-code
claude remote-control
```

That session then appears in the Claude app, so you can steer it from your phone while
it runs `xcodebuild`, installs to your iPhone and reads the console. (The Claude desktop
app works too.)

## 4. The M0 spike on your TX-RZ50

1. Pair the iPhone with the receiver (receiver on its **BLUETOOTH** input).
2. On the receiver: listening mode **Stereo**; Dirac Live **off**; dynamic features off.
3. In the app: **Settings (gear) › Measurement lab**.
   - Check: *Output is A2DP = Yes*, *HFP detected = No*, *Input is built-in mic = Yes*.
   - Set volume so a sweep is clearly audible but comfortable.
   - Run **10 sweeps** with the phone resting still at your seat.
4. Pass criteria (shown on screen):
   - Repeatability **≤ ±0.5 dB** from 100 Hz to 10 kHz.
   - Drift reported consistently (a few to a few hundred ppm is normal).
   - No HFP at any point.
5. Tap **Prepare export → Share results** and send me the JSON. It contains the measured
   responses, latency, drift and noise floor I need to tune thresholds.

Developer builds also have **Settings › Developer › Pretend mic is calibrated**, which runs
the full sweep flow with a flat placeholder curve. It's useful for exercising the whole app
before real calibration curves exist. Never ship that.

## Moving to the new repo

This session couldn't create repositories (GitHub returned 403), so the code lives on
branch `claude/iphone-room-acoustics-app-ya13nw` of `Complete-Python-3-Bootcamp`, all
inside `AudioMagician/` plus the CI workflow. To move it with history:

1. Create an empty private repo named `audio-magician` on GitHub (no README).
2. On any machine with git:
   ```bash
   git clone -b claude/iphone-room-acoustics-app-ya13nw https://github.com/bearysh/Complete-Python-3-Bootcamp.git am
   cd am
   git subtree split --prefix=AudioMagician -b am-only
   mkdir ../audio-magician && cd ../audio-magician && git init -b main
   git pull ../am am-only
   mkdir -p .github/workflows && cp ../am/.github/workflows/audio-magician.yml .github/workflows/
   sed -i '' 's#AudioMagician/##g; s#working-directory: AudioMagician#working-directory: .#' .github/workflows/audio-magician.yml
   git add . && git commit -m "Add CI"
   git remote add origin https://github.com/<you>/audio-magician.git && git push -u origin main
   ```
3. Or simply tell me the repo once it exists and connect it to Claude. I'll do the move
   and fix up the CI paths.
