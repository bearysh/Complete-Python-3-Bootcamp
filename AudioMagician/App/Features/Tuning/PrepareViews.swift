import SwiftUI
import SignalKit
import ReceiverKit

// MARK: Connect Bluetooth

struct ConnectView: View {
    @Environment(TuningFlow.self) private var flow
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        let route = model.audio.route
        StepScaffold(mood: route.isReady ? .success : .listening, eyebrow: "Step 4 of 4 · Connect",
                     title: route.isReady ? "Connected to \(route.outputName)" : "Connect to your receiver",
                     subtitle: route.isReady ? "Sound from your iPhone will now play through your speakers." : "Pair your iPhone with your \(flow.profile.model) over Bluetooth, just like headphones.") {
            HStack {
                Spacer()
                ZStack {
                    Ripples(active: !route.isReady, color: Theme.aurora).frame(width: 260, height: 260)
                    Image(systemName: route.isReady ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(route.isReady ? Theme.aurora : .white)
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
            }
            if !route.isReady {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        IconRow(systemImage: "1.circle", title: "Switch your receiver to Bluetooth", detail: flow.profile.menu(.bluetoothInput)?.note ?? flow.profile.menu(.bluetoothInput)?.display)
                        IconRow(systemImage: "2.circle", title: "Open Settings › Bluetooth on your iPhone", detail: "Tap your receiver's name (it usually starts with \"\(flow.profile.brand)\").")
                        IconRow(systemImage: "3.circle", title: "Come back here", detail: "We'll notice the moment it connects.")
                    }
                }
                if route.outputIsHFP {
                    GlassCard {
                        IconRow(systemImage: "exclamationmark.triangle", title: "Wrong kind of Bluetooth connection",
                                detail: "Your iPhone is using a phone-call connection, which takes over the microphone. Disconnect and reconnect your receiver, then come back.", tint: Theme.coral)
                    }
                }
                #if targetEnvironment(simulator)
                GlassCard { IconRow(systemImage: "desktopcomputer", title: "Simulator", detail: "Bluetooth isn't available here. Continue to preview the flow.", tint: Theme.mist) }
                #endif
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.coral)
            }
        } actions: {
            #if targetEnvironment(simulator)
            PrimaryButton(title: "Continue") { flow.advance(from: .connect) }
            #else
            PrimaryButton(title: "Continue", isEnabled: route.isReady) { flow.advance(from: .connect) }
            if !route.isReady {
                SecondaryButton(title: "Open Bluetooth settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            #endif
        }
        .task {
            do { try model.audio.activate() } catch { self.error = error.localizedDescription }
            // Route-change notifications cover most cases; poll gently as a fallback.
            while !Task.isCancelled {
                model.audio.refreshRoute()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: Receiver checklist

struct ReceiverChecklistView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var done: Set<MenuKey> = []

    struct Item: Identifiable {
        var id: MenuKey
        var title: String
        var why: String
    }

    private var items: [Item] {
        let name = flow.profile.roomCorrectionSystems.first ?? "Room correction"
        let correction = flow.setup.correction == .keep
            ? "Leave \(name) on, with the filter you normally use"
            : "Turn \(name) off"
        return [
            Item(id: .stereoMode, title: "Choose Stereo listening mode", why: "So each test sound plays from exactly one speaker."),
            Item(id: .dynamicFeaturesOff, title: "Switch off dynamic and loudness features", why: "They change the sound while we measure."),
            Item(id: .roomCorrectionToggle, title: correction, why: flow.setup.correction == .keep ? "We'll fine-tune around it." : "We'll replace it with a plan you can see."),
        ]
    }

    var body: some View {
        StepScaffold(eyebrow: "Get ready", title: "A few receiver settings",
                     subtitle: "Grab your remote. Tap each card when it's done.") {
            ForEach(items) { item in
                let key = item.id
                let isDone = done.contains(key)
                Button {
                    withAnimation(.spring(duration: 0.4)) {
                        if isDone { done.remove(key) } else { done.insert(key) }
                    }
                } label: {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            IconRow(systemImage: "circle", title: item.title, detail: item.why, tint: isDone ? Theme.aurora : Theme.lumen, done: isDone)
                            if let menu = flow.profile.menu(key) {
                                MenuPathView(menu: menu).padding(.leading, 54)
                            }
                        }
                    }
                    .opacity(isDone ? 0.7 : 1)
                }
                .buttonStyle(PressableStyle())
                .sensoryFeedback(.success, trigger: isDone)
            }
            if !flow.profile.verified {
                Text("Menu names may differ slightly on your receiver. Look for the closest match.")
                    .font(.footnote).foregroundStyle(Theme.mist)
            }
        } actions: {
            PrimaryButton(title: done.count == items.count ? "All set" : "Continue", isEnabled: done.count == items.count) {
                flow.advance(from: .checklist)
            }
            SecondaryButton(title: "Skip") { flow.advance(from: .checklist) }
        }
    }
}

struct MenuPathView: View {
    let menu: MenuPath

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(Array(menu.steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 6) {
                        Text(step)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(.white)
                        if i < menu.steps.count - 1 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.mist)
                        }
                    }
                }
            }
            if let note = menu.note {
                Text(note).font(.caption).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Wrapping horizontal layout for menu breadcrumbs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: Placement

struct PlacementView: View {
    @Environment(TuningFlow.self) private var flow

    var body: some View {
        StepScaffold(eyebrow: "Get ready", title: "Place your iPhone",
                     subtitle: "Where your head would be in your favourite seat.") {
            HStack {
                Spacer()
                PhonePlacementIllustration().frame(width: 200, height: 220)
                Spacer()
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    IconRow(systemImage: "arrow.up", title: "Screen up, at ear height", detail: "Rest it on a cushion, a stack of books or the top of the sofa back.")
                    IconRow(systemImage: "hand.raised.slash", title: "Hands off", detail: "Holding it adds noise. Set it down and sit nearby.", tint: Theme.orchid)
                    IconRow(systemImage: "speaker.slash", title: "Keep the bottom edge clear", detail: "That's where the microphone is.", tint: Theme.aurora)
                }
            }
        } actions: {
            PrimaryButton(title: "It's in place") { flow.advance(from: .placement) }
        }
    }
}

struct PhonePlacementIllustration: View {
    @State private var float = false

    var body: some View {
        ZStack {
            Ellipse().fill(Theme.lumen.opacity(0.15)).frame(width: 160, height: 36).offset(y: 80).blur(radius: 6)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.plum, Theme.dusk], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5))
                .frame(width: 150, height: 74)
                .rotation3DEffect(.degrees(58), axis: (x: 1, y: 0, z: 0))
                .offset(y: float ? 20 : 26)
            Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(Theme.aurora)
                .offset(y: float ? -40 : -34)
                .opacity(float ? 1 : 0.6)
        }
        .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { float.toggle() } }
        .accessibilityHidden(true)
    }
}

// MARK: Quiet check

struct QuietCheckView: View {
    @Environment(TuningFlow.self) private var flow
    @Environment(AppModel.self) private var model
    @State private var meter = LiveMeter()
    @State private var level: Double = -90
    @State private var history: [Double] = []
    @State private var lowHum = false
    @State private var finished = false

    /// Rough threshold in dBFS; refined to SPL once the mic is calibrated (v1.1).
    private let quietThreshold = -58.0

    var quiet: Bool { level < quietThreshold }

    var body: some View {
        StepScaffold(mood: quiet ? .success : .listening, eyebrow: "Listening", title: finished ? (quiet ? "Lovely and quiet" : "A little noisy") : "Shh… listening to your room",
                     subtitle: finished
                        ? (quiet ? "Background noise is low enough for clear measurements." : (lowHum ? "Something is humming low, maybe a fridge, fan or air conditioning. Pause it if you can." : "There's some background sound. Pausing noisy things will give cleaner results."))
                        : "Stay still for a few seconds while we hear the room's background sound.") {
            HStack {
                Spacer()
                SoundOrb(level: max(0, (level + 80) / 50), mood: quiet ? .success : .listening, size: 240)
                Spacer()
            }
        } actions: {
            PrimaryButton(title: finished ? "Continue" : "Listening…", isEnabled: finished) {
                meter.stop()
                flow.advance(from: .quiet)
            }
        }
        .task { await listen() }
        .onDisappear { meter.stop() }
    }

    private func listen() async {
        try? model.audio.activate()
        var bandBlocks: [ClosedRange<Double>: [Double]] = [:]
        var lowBlocks: [Double] = []
        do {
            try meter.start { block, rate in
                let l = Levels.bandLevelDB(block, sampleRate: rate, band: 100...8_000)
                level = l
                history.append(l)
                for band in [250.0...4_000, 30.0...120] {
                    bandBlocks[band, default: []].append(Levels.bandLevelDB(block, sampleRate: rate, band: band))
                }
                lowBlocks.append(Levels.bandLevelDB(block, sampleRate: rate, band: 30...150))
            }
        } catch {
            finished = true
            return
        }
        try? await Task.sleep(for: .seconds(4))
        meter.stop()
        for (band, values) in bandBlocks {
            let sorted = values.sorted()
            flow.quietLevels[band] = sorted.isEmpty ? -90 : sorted[sorted.count / 2]
        }
        let median = history.sorted().dropFirst(history.count / 2).first ?? level
        flow.quietBroadbandDB = median
        level = median
        let low = lowBlocks.sorted().dropFirst(lowBlocks.count / 2).first ?? -90
        lowHum = low > median + 6
        withAnimation(.spring) { finished = true }
    }
}

// MARK: Volume check

struct VolumeCheckView: View {
    @Environment(TuningFlow.self) private var flow
    @Environment(AppModel.self) private var model
    @State private var meter = LiveMeter()
    @State private var level: Double = -90
    @State private var running = false

    /// Target window for pink noise at the seat, dBFS (≈ 70–80 dB SPL on current iPhones; refined with calibration).
    private let target = -40.0 ... -26.0
    private let floor = -70.0, ceiling = -10.0

    private var normalized: Double { (level - floor) / (ceiling - floor) }
    private var targetNormalized: ClosedRange<Double> { ((target.lowerBound - floor) / (ceiling - floor))...((target.upperBound - floor) / (ceiling - floor)) }
    private var advice: String {
        if !running { return "We'll play a soft hiss through your speakers. Adjust your receiver's volume until the ring glows teal." }
        if level < target.lowerBound { return "A little louder, please. Turn the volume up slowly." }
        if level > target.upperBound { return "That's plenty. Turn it down a touch." }
        return "Just right. Leave the volume here until we're done."
    }

    var body: some View {
        let inTarget = running && target.contains(level)
        StepScaffold(mood: inTarget ? .success : .listening, eyebrow: "Get ready", title: "Set the volume", subtitle: advice) {
            HStack {
                Spacer()
                ZStack {
                    TargetRing(value: running ? normalized : 0, target: targetNormalized).frame(width: 240, height: 240)
                    SoundOrb(level: running ? max(0, normalized) : 0, mood: inTarget ? .success : .listening, size: 170)
                }
                Spacer()
            }
            .sensoryFeedback(.success, trigger: inTarget)
        } actions: {
            PrimaryButton(title: inTarget ? "Sounds right" : (running ? "Adjusting…" : "Play test sound"), systemImage: running ? nil : "play.fill", isEnabled: !running || inTarget) {
                if running {
                    meter.stop()
                    running = false
                    flow.advance(from: .volume)
                } else {
                    start()
                }
            }
            if running && !inTarget {
                SecondaryButton(title: "Continue anyway") {
                    meter.stop()
                    running = false
                    flow.advance(from: .volume)
                }
            }
        }
        .onDisappear { meter.stop() }
    }

    private func start() {
        try? model.audio.activate()
        let noise = PinkNoise.generate(count: 48_000 * 4, rmsDB: -20)
        do {
            try meter.start(playing: noise) { block, rate in
                let l = Levels.bandLevelDB(block, sampleRate: rate, band: 100...8_000)
                // Gentle smoothing so the ring doesn't jitter.
                level = level < -85 ? l : level * 0.7 + l * 0.3
            }
            running = true
        } catch {
            running = false
        }
    }
}
