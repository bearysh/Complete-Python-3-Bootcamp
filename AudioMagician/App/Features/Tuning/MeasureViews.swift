import SwiftUI
import SwiftData
import SignalKit
import ReceiverKit
import RoomAnalysis

// MARK: Sweeps

/// Plays the sweep program at one seat. Used for the main seat, extra seats and verification.
struct SweepPanel: View {
    var title: String
    var subtitle: String
    var onComplete: (ProgramResult) -> Void
    @Environment(AppModel.self) private var model
    @State private var runner = SweepRunner()
    @State private var started = false

    private var mood: Theme.Mood {
        switch runner.phase {
        case .problem: .attention
        case .done: .success
        case .idle: .calm
        case .listeningToRoom: .listening
        default: .measuring
        }
    }

    private var phaseText: String {
        switch runner.phase {
        case .idle: "Ready when you are. Sit still and keep quiet for about half a minute."
        case .listeningToRoom: "Listening to the quiet room…"
        case .playing(.left): "Left speaker"
        case .playing(.right): "Right speaker"
        case .playing(.both): "Both together, with your subwoofer"
        case .analyzing: "Making sense of what we heard…"
        case .done: "Got it."
        case .problem(let msg): msg
        }
    }

    var body: some View {
        StepScaffold(mood: mood, eyebrow: "Measuring", title: title, subtitle: subtitle) {
            VStack(spacing: 22) {
                ZStack {
                    Ripples(active: { if case .playing = runner.phase { return true } else { return false } }(), color: Theme.orchid)
                        .frame(width: 300, height: 300)
                    SoundOrb(level: runner.progress * 0.2, mood: mood, pulse: { if case .playing = runner.phase { return true } else { return false } }(), size: 220)
                }
                .frame(maxWidth: .infinity)
                Text(phaseText)
                    .font(.headlineRounded)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: phaseText)
                if started, runner.phase != .done {
                    ProgressView(value: runner.progress)
                        .tint(Theme.orchid)
                    if runner.attempt > 1 {
                        Text("Try \(runner.attempt) of \(runner.maxAttempts)").font(.caption).foregroundStyle(Theme.mist)
                    }
                }
            }
        } actions: {
            switch runner.phase {
            case .idle:
                PrimaryButton(title: "Start", systemImage: "play.fill", tint: Theme.orchid) { run() }
            case .problem:
                PrimaryButton(title: "Try again", systemImage: "arrow.clockwise") { run() }
            default:
                PrimaryButton(title: "Measuring…", isEnabled: false) {}
            }
        }
        .navigationBarBackButtonHidden(started && runner.phase != .idle && !isProblem)
    }

    private var isProblem: Bool { if case .problem = runner.phase { return true } else { return false } }

    private func run() {
        started = true
        Task {
            try? model.audio.activate()
            #if targetEnvironment(simulator)
            // No Bluetooth in the simulator: show the flow with a short pause.
            try? await Task.sleep(for: .seconds(2))
            #endif
            if let result = await runner.measure() {
                try? await Task.sleep(for: .milliseconds(600))
                onComplete(result)
            }
        }
    }
}

struct SweepSeatView: View {
    var seatIndex: Int
    @Environment(TuningFlow.self) private var flow

    var body: some View {
        SweepPanel(title: seatIndex == 0 ? "Your main seat" : "Seat \(seatIndex + 1)",
                   subtitle: "We'll play a rising tone through each front speaker. It's normal for it to sound like a slide whistle.") { result in
            flow.seats.removeAll { $0.id == seatIndex }
            flow.seats.append(SeatMeasurement(id: seatIndex, program: result))
            flow.advance(from: .sweeps)
        }
    }
}

struct MoreSeatsView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var measuringSeat: Int?

    var body: some View {
        if let seat = measuringSeat {
            SweepPanel(title: "Seat \(seat + 1)", subtitle: "Move your iPhone to the next seat, at ear height, then start.") { result in
                flow.seats.removeAll { $0.id == seat }
                flow.seats.append(SeatMeasurement(id: seat, program: result))
                withAnimation { measuringSeat = nil }
            }
        } else {
            overview
        }
    }

    private var overview: some View {
        @Bindable var flow = flow
        let measured = Set(flow.seats.map(\.id))
        let next = (0..<flow.plannedSeats).first { !measured.contains($0) }
        return StepScaffold(eyebrow: "More seats", title: next == nil ? "Every seat measured" : "Now a few more seats",
                            subtitle: "Bass changes a lot from seat to seat. Measuring around your sofa means our advice works for everyone, not just one spot.") {
            RoomDiagram(channels: flow.setup.layout.channels.map { ch in
                let p = ch.diagramPosition
                return .init(id: ch.rawValue, label: ch.shortName, x: p.x, y: p.y, active: true)
            }, seats: (0..<flow.plannedSeats).map { i in
                .init(id: i, x: 0.3 + 0.4 * Double(i) / Double(max(flow.plannedSeats - 1, 1)), done: measured.contains(i), current: i == next)
            })
            .frame(height: 260)
            Stepper("Seats to measure: \(flow.plannedSeats)", value: $flow.plannedSeats, in: max(2, measured.count)...5)
                .foregroundStyle(.white)
        } actions: {
            if let next {
                PrimaryButton(title: "Measure seat \(next + 1)", tint: Theme.orchid) { withAnimation { measuringSeat = next } }
                SecondaryButton(title: "That's enough, show my results") { flow.advance(from: .seats) }
            } else {
                PrimaryButton(title: "See my results", systemImage: "sparkles") { flow.advance(from: .seats) }
            }
        }
    }
}

// MARK: Test-tone levels

struct ToneLevelsView: View {
    enum Mode { case measure, verify }
    var mode: Mode
    var onFinish: (([ToneReading]) -> Void)?

    @Environment(TuningFlow.self) private var flow
    @Environment(AppModel.self) private var model
    @State private var meter = LiveMeter()
    @State private var index = 0
    @State private var segmenter = ToneSegmenter(noiseFloorDB: -80)
    @State private var live: Double = -90
    @State private var readings: [ToneReading] = []
    @State private var waitingForUser = true
    @State private var justMeasured = 0

    private var channels: [SpeakerChannel] { flow.toneChannels }
    private var current: SpeakerChannel? { index < channels.count ? channels[index] : nil }

    var body: some View {
        StepScaffold(mood: stateMood, eyebrow: "Speaker levels · \(min(index + 1, channels.count)) of \(channels.count)",
                     title: current.map { waitingForUser ? "Select \($0.displayName)" : "Listening to \($0.displayName)" } ?? "All speakers measured",
                     subtitle: subtitle) {
            RoomDiagram(channels: flow.setup.layout.channels.map { ch in
                let p = ch.diagramPosition
                return .init(id: ch.rawValue, label: ch.shortName, x: p.x, y: p.y, active: readings.contains { $0.channel == ch })
            }, highlight: current?.rawValue)
            .frame(height: 240)

            if index == 0, waitingForUser, let menu = flow.profile.menu(.testTone) {
                GlassCard { MenuPathView(menu: menu) }
            }
            if let current, !waitingForUser {
                HStack(spacing: 16) {
                    SoundOrb(level: max(0, (live + 70) / 50), mood: .listening, size: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(progressText).font(.headlineRounded).foregroundStyle(.white)
                        Text(current.isSubwoofer ? "Low rumble from the subwoofer" : "A steady hiss from this speaker").font(.subheadline).foregroundStyle(Theme.mist)
                    }
                }
            }
        } actions: {
            if current != nil {
                if waitingForUser {
                    PrimaryButton(title: "It's playing", systemImage: "waveform", tint: Theme.aurora) { listen() }
                } else {
                    PrimaryButton(title: "Listening…", isEnabled: false) {}
                }
                SecondaryButton(title: "Skip this speaker") { advance() }
            } else {
                PrimaryButton(title: mode == .measure ? "Continue" : "Compare") { finish() }
            }
        }
        .sensoryFeedback(.success, trigger: justMeasured)
        .onDisappear { meter.stop() }
    }

    private var stateMood: Theme.Mood {
        if current == nil { return .success }
        return waitingForUser ? .calm : .listening
    }

    private var subtitle: String {
        guard let current else { return "Nice work. Turn the test tone off on your receiver." }
        if waitingForUser {
            return index == 0
                ? "On your receiver, open the test tone menu and move to \(current.displayName). When you hear it, tap below."
                : "Move to \(current.displayName) on your receiver. When you hear it, tap below."
        }
        return "Hold still for a couple of seconds."
    }

    private var progressText: String {
        switch segmenter.state {
        case .waiting: "Waiting for the tone…"
        case .settling(let p): "Measuring… \(Int(p * 100))%"
        case .measured: "Got it"
        }
    }

    private func listen() {
        guard let ch = current else { return }
        let band = ToneReading.band(for: ch)
        segmenter = ToneSegmenter(noiseFloorDB: flow.quietLevels[band] ?? -85)
        waitingForUser = false
        meter.stop()
        try? model.audio.activate()
        do {
            try meter.start { block, rate in
                let l = Levels.bandLevelDB(block, sampleRate: rate, band: band)
                live = l
                if case .measured(let level) = segmenter.feed(l) {
                    meter.stop()
                    readings.removeAll { $0.channel == ch }
                    readings.append(ToneReading(channel: ch, levelDB: level, band: band))
                    justMeasured += 1
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        advance()
                    }
                }
            }
        } catch {
            waitingForUser = true
        }
        #if targetEnvironment(simulator)
        // Simulator has no receiver: fake a reading so the flow can be previewed.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            meter.stop()
            readings.append(ToneReading(channel: ch, levelDB: -30 + Double.random(in: -3...3), band: band))
            justMeasured += 1
            advance()
        }
        #endif
    }

    private func advance() {
        withAnimation(.spring) {
            index += 1
            waitingForUser = true
        }
    }

    private func finish() {
        meter.stop()
        switch mode {
        case .measure:
            flow.tones = readings
            flow.advance(from: .tones)
        case .verify:
            onFinish?(readings)
        }
    }
}

// MARK: Analyzing

struct AnalyzingView: View {
    @Environment(TuningFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @State private var message = 0
    private let messages = ["Lining up every sound we heard…", "Comparing your seats…", "Matching it to your receiver's settings…", "Writing your plan…"]

    var body: some View {
        ZStack {
            AuraBackground(mood: .measuring)
            VStack(spacing: 30) {
                SoundOrb(level: 0.25, mood: .measuring, pulse: true, size: 240)
                Text(messages[message % messages.count])
                    .font(.headlineRounded)
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: message)
            }
        }
        .task {
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.2))
                    message += 1
                }
            }
            let start = Date()
            await flow.analyze()
            save()
            // Let the moment breathe; analysis is usually faster than this.
            let wait = max(0, 3.0 - Date().timeIntervalSince(start))
            try? await Task.sleep(for: .seconds(wait))
            ticker.cancel()
            flow.path = [.results]
        }
    }

    private func save() {
        guard let analysis = flow.analysis, let plan = flow.plan else { return }
        let name = flow.roomName
        let existing = try? context.fetch(FetchDescriptor<Room>(predicate: #Predicate { $0.name == name })).first
        let room = existing ?? Room(name: name, setup: flow.setup)
        if existing == nil { context.insert(room) }
        room.setupData = (try? JSONEncoder().encode(flow.setup)) ?? room.setupData
        let record = TuningRecord(session: flow.session, analysis: analysis, plan: plan)
        record.room = room
        context.insert(record)
        try? context.save()
        flow.savedRecord = record
    }
}
