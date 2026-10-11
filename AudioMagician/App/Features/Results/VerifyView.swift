import SwiftUI
import Charts
import SignalKit
import ReceiverKit
import RoomAnalysis

/// "Check your work": re-measure the main seat and show before/after.
struct VerifyView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var stage: Stage = .intro

    enum Stage { case intro, measuring, compare }

    var body: some View {
        switch stage {
        case .intro:
            StepScaffold(mood: .calm, eyebrow: "Check your work", title: "Let's hear the difference",
                         subtitle: flow.calibrated
                            ? "Put your iPhone back in your main seat. We'll measure once more and compare."
                            : "We'll play the test tones once more and compare your speaker levels.") {
                HStack { Spacer(); SoundOrb(level: 0.2, mood: .calm, size: 220); Spacer() }
            } actions: {
                PrimaryButton(title: "Measure again", systemImage: "arrow.triangle.2.circlepath") { withAnimation { stage = .measuring } }
            }
        case .measuring:
            if flow.calibrated {
                SweepPanel(title: "Your main seat", subtitle: "Same place as before, please.") { result in
                    flow.verifySeat = SeatMeasurement(id: 0, program: result)
                    withAnimation { stage = .compare }
                }
            } else {
                ToneLevelsView(mode: .verify) { readings in
                    flow.verifyTones = readings
                    withAnimation { stage = .compare }
                }
            }
        case .compare:
            CompareView()
        }
    }
}

struct CompareView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var celebrate = 0

    var body: some View {
        StepScaffold(mood: .success, eyebrow: "Before & after", title: "Nicely done",
                     subtitle: flow.calibrated ? "The gold line is your room now. Closer to the dotted line is better." : "Bars closer to zero mean better-matched speakers.") {
            if flow.calibrated { responseComparison } else { levelComparison }
        } actions: {
            PrimaryButton(title: "Finish", systemImage: "sparkles") { flow.path = [.results] }
        }
        .onAppear { celebrate += 1 }
        .sensoryFeedback(.success, trigger: celebrate)
    }

    private var responseComparison: some View {
        let before = flow.seats.first { $0.id == 0 }?.program.sweep(.both)?.response
        let after = flow.verifySeat?.program.sweep(.both)?.response
        let cal = flow.capability.calibration
        let ref = before.map { (cal?.apply(to: $0) ?? $0).smoothed(fraction: 1).meanLevel(in: 200...2_000) } ?? 0
        struct P: Identifiable { var id: String { "\(s)\(f)" }; var s: String; var f: Double; var db: Double }
        var pts: [P] = []
        for (name, r) in [("Before", before), ("After", after)] {
            guard let r else { continue }
            let c = (cal?.apply(to: r) ?? r).smoothed(fraction: 6)
            for i in stride(from: 0, to: c.frequencies.count, by: 3) where c.frequencies[i] >= 15 && c.frequencies[i] <= 500 {
                pts.append(P(s: name, f: c.frequencies[i], db: c.db[i] - ref))
            }
        }
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bass at your main seat").font(.headlineRounded).foregroundStyle(.white)
                Chart(pts) { p in
                    LineMark(x: .value("Hz", p.f), y: .value("dB", p.db), series: .value("When", p.s))
                        .foregroundStyle(p.s == "After" ? Theme.lumen : Theme.mist.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: p.s == "After" ? 2.5 : 1.5, dash: p.s == "After" ? [] : [3, 3]))
                        .interpolationMethod(.monotone)
                    RuleMark(y: .value("Target", 0)).foregroundStyle(Theme.aurora.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartXScale(domain: 15...500, type: .log)
                .chartYScale(domain: -18...18)
                .frame(height: 220)
            }
        }
    }

    private var levelComparison: some View {
        struct B: Identifiable { var id: String { "\(when)\(ch)" }; var when: String; var ch: String; var db: Double }
        func offsets(_ t: [ToneReading]) -> [(SpeakerChannel, Double)] {
            let fronts = t.filter { $0.channel.isFrontPair }.map(\.levelDB)
            let ref = fronts.isEmpty ? (t.first?.levelDB ?? 0) : fronts.reduce(0, +) / Double(fronts.count)
            return t.filter { !$0.channel.isSubwoofer }.map { ($0.channel, $0.levelDB - ref) }
        }
        let bars = offsets(flow.tones).map { B(when: "Before", ch: $0.0.shortName, db: $0.1) }
            + offsets(flow.verifyTones).map { B(when: "After", ch: $0.0.shortName, db: $0.1) }
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Speaker levels").font(.headlineRounded).foregroundStyle(.white)
                Chart(bars) { b in
                    BarMark(x: .value("Speaker", b.ch), y: .value("dB", b.db))
                        .foregroundStyle(by: .value("When", b.when))
                        .position(by: .value("When", b.when))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(["Before": Theme.mist.opacity(0.5), "After": Theme.aurora])
                .chartYScale(domain: -8...8)
                .frame(height: 220)
            }
        }
    }
}
