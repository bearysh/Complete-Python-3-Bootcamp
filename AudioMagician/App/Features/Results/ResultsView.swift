import SwiftUI
import RoomAnalysis
import Recommendations

struct ResultsView: View {
    var close: () -> Void
    @Environment(TuningFlow.self) private var flow

    var body: some View {
        if let analysis = flow.analysis {
            content(analysis)
        } else {
            StepScaffold(mood: .attention, title: "No results yet", subtitle: "Something interrupted the measurement. Please try again.") {
                EmptyView()
            } actions: {
                PrimaryButton(title: "Close", action: close)
            }
        }
    }

    private func content(_ a: AnalysisResult) -> some View {
        let visible = a.findings.filter { $0.kind != .subLevelNeedsCalibration || !a.calibrated }
        return StepScaffold(mood: .success, eyebrow: flow.roomName, title: ScoreCopy.headline(score: a.score),
                            subtitle: visible.isEmpty ? "We didn't find anything worth changing. Enjoy the music." : "Here's what we heard, in plain words.") {
            HStack {
                Spacer()
                ScoreRing(score: a.score).frame(width: 170, height: 170)
                Spacer()
            }
            .padding(.vertical, 8)

            VStack(spacing: 12) {
                ForEach(Array(visible.prefix(6).enumerated()), id: \.element.id) { i, f in
                    FindingCard(finding: f)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(duration: 0.6).delay(0.15 * Double(i)), value: a.score)
                }
            }

            if !a.calibrated {
                GlassCard {
                    IconRow(systemImage: "info.circle", title: "Measured in Levels & distances mode",
                            detail: "Your iPhone's microphone calibration isn't ready yet, so bass and EQ advice will appear in a future update.", tint: Theme.mist)
                }
            }

            if a.calibrated {
                Button { flow.go(.details) } label: {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                        Text("See the details")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.mist)
                    .padding(.vertical, 6)
                }
            } else if !a.tones.isEmpty {
                Button { flow.go(.details) } label: {
                    HStack {
                        Image(systemName: "chart.bar")
                        Text("See speaker levels")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.mist)
                }
            }
        } actions: {
            PrimaryButton(title: "See your fix plan", systemImage: "list.bullet.rectangle") { flow.go(.plan) }
            if flow.isReview {
                SecondaryButton(title: "Done", action: close)
            }
        }
    }
}

struct FindingCard: View {
    let finding: Finding

    var body: some View {
        let copy = FindingCopy.make(for: finding)
        let tint = Theme.color(for: finding.severity.rawValue)
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Pill(text: copy.tag, tint: tint)
                    Spacer()
                    SeverityDots(level: finding.severity.rawValue, tint: tint)
                }
                Text(copy.headline).font(.headlineRounded).foregroundStyle(.white)
                Text(copy.body).font(.subheadline).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                    Text(copy.fixHint)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SeverityDots: View {
    var level: Int
    var tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(i <= level ? tint : Color.white.opacity(0.15)).frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel(["Small", "Noticeable", "Big"][min(level, 2)] + " effect")
    }
}
