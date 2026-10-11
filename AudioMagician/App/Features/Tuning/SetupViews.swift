import SwiftUI
import ReceiverKit

// MARK: Speakers

struct SpeakersView: View {
    @Environment(TuningFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        StepScaffold(eyebrow: "Step 1 of 4 · Your setup", title: "Which speakers do you have?",
                     subtitle: "Pick the layout that matches your room. You can tap a speaker to add or remove it.") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(SpeakerLayout.presets) { preset in
                        let selected = preset.channels == flow.setup.layout.channels
                        Button { withAnimation(.spring) { flow.setup.layout = preset } } label: {
                            Text(preset.name)
                                .font(.system(.headline, design: .rounded))
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(selected ? Theme.lumen : Color.white.opacity(0.07), in: Capsule())
                                .foregroundStyle(selected ? Theme.ink : .white)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)

            RoomDiagram(channels: SpeakerChannel.allCases.map { ch in
                let p = ch.diagramPosition
                return .init(id: ch.rawValue, label: ch.shortName, x: p.x, y: p.y, active: flow.setup.layout.channels.contains(ch))
            })
            .frame(height: 300)
            .overlay {
                // Invisible tap targets on each speaker.
                GeometryReader { geo in
                    ForEach(SpeakerChannel.allCases) { ch in
                        let p = ch.diagramPosition
                        Color.clear.contentShape(Rectangle())
                            .frame(width: 44, height: 44)
                            .position(x: geo.size.width * p.x, y: geo.size.height * p.y + 10)
                            .onTapGesture { toggle(ch) }
                            .accessibilityLabel(ch.displayName)
                            .accessibilityAddTraits(flow.setup.layout.channels.contains(ch) ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("How big are your front speakers?").font(.headlineRounded).foregroundStyle(.white)
                Picker("Front speakers", selection: $flow.setup.speakerSize) {
                    ForEach(SpeakerSize.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } actions: {
            PrimaryButton(title: "Continue") { flow.advance(from: .speakers) }
        }
    }

    private func toggle(_ ch: SpeakerChannel) {
        guard !ch.isFrontPair else { return }
        var channels = flow.setup.layout.channels
        if let i = channels.firstIndex(of: ch) { channels.remove(at: i) } else { channels.append(ch) }
        withAnimation(.spring) { flow.setup.layout = SpeakerLayout(name: "Custom", channels: channels) }
    }
}

// MARK: Room correction choice

struct CorrectionChoiceView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var showExplainer = false

    var body: some View {
        let name = flow.profile.roomCorrectionSystems.first ?? "Room correction"
        StepScaffold(eyebrow: "Step 2 of 4 · Your setup", title: "What about \(name)?",
                     subtitle: "Your receiver has its own room correction. You can keep it or let us guide you instead.") {
            choice(.keep, title: "Keep \(name)", detail: "We'll fine-tune what sits on top of it: levels, distances and bass blending.", icon: "checkmark.shield")
            choice(.turnOff, title: "Turn it off and follow our plan", detail: "We'll guide every setting, including EQ.", icon: "wand.and.stars")
            Button("Not sure? Here's the difference") { showExplainer = true }
                .font(.subheadline)
                .tint(Theme.mist)
        } actions: {
            PrimaryButton(title: "Continue") { flow.advance(from: .correction) }
        }
        .sheet(isPresented: $showExplainer) {
            ExplainerSheet(title: "Keep it, or go manual?", paragraphs: [
                "\(name) measures your room and automatically adjusts your receiver. If you've already run it and like the sound, keeping it is a great choice.",
                "Going manual gives you clear, explainable settings that you can see and change. It's ideal if you never ran \(name), or the sound feels off.",
                "You can always come back and try the other way.",
            ])
            .presentationDetents([.medium])
        }
    }

    private func choice(_ c: RoomCorrectionChoice, title: String, detail: String, icon: String) -> some View {
        let selected = flow.setup.correction == c
        return Button { withAnimation(.spring) { flow.setup.correction = c } } label: {
            GlassCard {
                HStack {
                    IconRow(systemImage: icon, title: title, detail: detail, tint: selected ? Theme.lumen : Theme.mist)
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Theme.lumen : Theme.mist)
                        .font(.title3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(selected ? Theme.lumen.opacity(0.6) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
    }
}

struct ExplainerSheet: View {
    var title: String
    var paragraphs: [String]

    var body: some View {
        ZStack {
            AuraBackground()
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.display(26)).foregroundStyle(.white)
                ForEach(paragraphs, id: \.self) { Text($0).foregroundStyle(Theme.mist) }
                Spacer()
            }
            .padding(28)
        }
    }
}

// MARK: Distances

struct DistancesView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var measuring: SpeakerChannel?
    @State private var useFeet = Locale.current.measurementSystem == .us

    var body: some View {
        StepScaffold(eyebrow: "Step 3 of 4 · Optional", title: "How far is each speaker?",
                     subtitle: "Measure from your main seat to each speaker. Use a tape measure, or tap the camera to measure with your iPhone.") {
            Picker("Units", selection: $useFeet) {
                Text("Metres").tag(false)
                Text("Feet").tag(true)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 10) {
                ForEach(flow.setup.layout.channels) { ch in
                    DistanceRow(channel: ch, useFeet: useFeet, meters: binding(for: ch)) { measuring = ch }
                }
            }
        } actions: {
            PrimaryButton(title: flow.setup.distances.isEmpty ? "Skip for now" : "Continue") { flow.advance(from: .distances) }
        }
        .fullScreenCover(item: $measuring) { ch in
            ARDistanceView(channel: ch) { meters in
                if let meters { flow.setup.distances[ch] = meters }
                measuring = nil
            }
        }
    }

    private func binding(for ch: SpeakerChannel) -> Binding<Double?> {
        Binding(get: { flow.setup.distances[ch] }, set: { flow.setup.distances[ch] = $0 })
    }
}

struct DistanceRow: View {
    let channel: SpeakerChannel
    let useFeet: Bool
    @Binding var meters: Double?
    var onCamera: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(channel.displayName).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(width: 70)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: text) { _, v in
                    let n = Double(v.replacingOccurrences(of: ",", with: "."))
                    meters = n.map { useFeet ? $0 * 0.3048 : $0 }
                }
            Text(useFeet ? "ft" : "m").foregroundStyle(Theme.mist).frame(width: 20)
            Button(action: onCamera) { Image(systemName: "camera.viewfinder").font(.title3) }
                .tint(Theme.lumen)
                .accessibilityLabel("Measure \(channel.displayName) with camera")
        }
        .onAppear(perform: syncText)
        .onChange(of: useFeet) { _, _ in syncText() }
        .onChange(of: meters) { _, _ in if !focused { syncText() } }
    }

    private func syncText() {
        guard let m = meters else { text = ""; return }
        text = String(format: "%.2f", useFeet ? m / 0.3048 : m)
    }
}
