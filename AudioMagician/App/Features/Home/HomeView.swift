import SwiftUI
import SwiftData
import ReceiverKit
import Recommendations

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Room.createdAt, order: .reverse) private var rooms: [Room]
    @State private var flow: TuningFlow?
    @State private var showSettings = false
    @State private var showReceiverPicker = false

    var body: some View {
        NavigationStack {
            StepScaffold(eyebrow: "Audio Magician", title: rooms.isEmpty ? "Let's tune your room" : "Your rooms",
                         subtitle: rooms.isEmpty ? "Measure your speakers and get a clear, step-by-step plan for your receiver." : nil) {
                if rooms.isEmpty {
                    HStack {
                        Spacer()
                        SoundOrb(level: 0.15, mood: .calm, size: 220)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                    capabilityNote
                } else {
                    VStack(spacing: 14) {
                        ForEach(rooms) { room in
                            RoomCard(room: room) { open(room) }
                        }
                    }
                    capabilityNote
                }
            } actions: {
                PrimaryButton(title: rooms.isEmpty ? "Start tuning" : "Tune again", systemImage: "wand.and.stars") {
                    showReceiverPicker = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .tint(Theme.mist)
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showReceiverPicker) {
                ReceiverPickerView { profile in
                    showReceiverPicker = false
                    flow = TuningFlow(profile: profile, capability: model.capability)
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: $flow) { flow in
                TuningFlowView(flow: flow) { self.flow = nil }
            }
        }
    }

    private var capabilityNote: some View {
        GlassCard {
            if model.capability.isCalibrated {
                IconRow(systemImage: "checkmark.seal", title: "Full measurement", detail: "Your iPhone's microphone is calibrated. You'll get levels, distances, crossover and EQ advice.", tint: Theme.aurora)
            } else {
                IconRow(systemImage: "slider.horizontal.3", title: "Levels & distances",
                        detail: "Your iPhone measures speaker levels precisely today. Full frequency and EQ advice arrives once your iPhone's microphone calibration is ready.",
                        tint: Theme.lumen)
            }
        }
    }

    private func open(_ room: Room) {
        guard let record = room.latest, let setup = room.setup, let profile = model.profile(id: setup.receiverID) else { return }
        let f = TuningFlow(review: record, profile: profile, capability: model.capability)
        f.path = [.results]
        flow = f
    }
}

extension TuningFlow: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct RoomCard: View {
    let room: Room
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCard {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                        Circle().trim(from: 0, to: Double(room.latest?.score ?? 0) / 100)
                            .stroke(Theme.aurora, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(room.latest?.score ?? 0)").font(.system(.headline, design: .rounded)).foregroundStyle(.white)
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room.name).font(.headlineRounded).foregroundStyle(.white)
                        if let date = room.latest?.date {
                            Text("Tuned \(date.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(Theme.mist)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.mist)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}

/// Launch: Onkyo TX-RZ50 only. More brands are listed as "coming soon".
struct ReceiverPickerView: View {
    @Environment(AppModel.self) private var model
    var onPick: (ReceiverProfile) -> Void

    var body: some View {
        ZStack {
            AuraBackground()
            VStack(alignment: .leading, spacing: 18) {
                Text("Which receiver do you have?").font(.display(26)).foregroundStyle(.white).padding(.top, 28)
                ForEach(model.profiles) { p in
                    Button { onPick(p) } label: {
                        GlassCard {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.brand).font(.caption2Rounded).foregroundStyle(Theme.lumen)
                                    Text(p.model).font(.headlineRounded).foregroundStyle(.white)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.mist)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
                GlassCard {
                    IconRow(systemImage: "sparkles", title: "More receivers coming soon", detail: "Yamaha and Denon, plus more Onkyo models.", tint: Theme.mist)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
}
