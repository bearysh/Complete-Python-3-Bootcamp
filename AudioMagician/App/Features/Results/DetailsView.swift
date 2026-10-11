import SwiftUI
import Charts
import SignalKit
import RoomAnalysis
import ReceiverKit

/// Optional, for the curious: the actual graphs.
struct DetailsView: View {
    @Environment(TuningFlow.self) private var flow
    @State private var channel: SweepChannel = .both
    @State private var smoothing: Double = 6
    @State private var showSeats = true

    var body: some View {
        StepScaffold(eyebrow: "Details", title: "What we measured") {
            if let a = flow.analysis {
                if a.calibrated, !a.responses.isEmpty { responseSection(a) }
                if !a.tones.isEmpty { levelsSection(a) }
                if !a.decay.isEmpty { decaySection(a) }
                if let seat = flow.seats.first?.program { diagnostics(seat) }
            }
        }
    }

    // MARK: Frequency response

    private func responseSection(_ a: AnalysisResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Frequency response").font(.headlineRounded).foregroundStyle(.white)
                Picker("Speaker", selection: $channel) {
                    Text("Left").tag(SweepChannel.left)
                    Text("Right").tag(SweepChannel.right)
                    Text("Both + sub").tag(SweepChannel.both)
                }
                .pickerStyle(.segmented)
                if let r = a.response(channel) {
                    ResponseChart(summary: r, smoothing: smoothing, showSeats: showSeats, reference: a.referenceLevel)
                        .frame(height: 240)
                }
                HStack {
                    Text("Smoothing").font(.caption).foregroundStyle(Theme.mist)
                    Picker("Smoothing", selection: $smoothing) {
                        Text("1/3").tag(3.0)
                        Text("1/6").tag(6.0)
                        Text("1/12").tag(12.0)
                        Text("1/24").tag(24.0)
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Show each seat", isOn: $showSeats).font(.subheadline).tint(Theme.orchid)
                Text("Grey areas were too close to background noise to trust.").font(.caption).foregroundStyle(Theme.mist)
            }
        }
    }

    // MARK: Levels

    private func levelsSection(_ a: AnalysisResult) -> some View {
        let fronts = a.tones.filter { $0.channel.isFrontPair }.map(\.levelDB)
        let ref = fronts.isEmpty ? (a.tones.first?.levelDB ?? 0) : fronts.reduce(0, +) / Double(fronts.count)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speaker levels").font(.headlineRounded).foregroundStyle(.white)
                Text("Compared with your front speakers (0 dB).").font(.caption).foregroundStyle(Theme.mist)
                Chart(a.tones, id: \.channel) { t in
                    BarMark(x: .value("Speaker", t.channel.shortName), y: .value("dB", t.levelDB - ref))
                        .foregroundStyle(abs(t.levelDB - ref) < 1 ? Theme.aurora : Theme.lumen)
                        .cornerRadius(4)
                }
                .chartYScale(domain: -8...8)
                .chartYAxis {
                    AxisMarks(values: [-6, -3, 0, 3, 6]) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: Decay

    private func decaySection(_ a: AnalysisResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How long sound lingers").font(.headlineRounded).foregroundStyle(.white)
                Text("Reverberation time (T20) per octave. Living rooms usually sit around 0.3–0.5 s.").font(.caption).foregroundStyle(Theme.mist)
                Chart(a.decay, id: \.center) { b in
                    BarMark(x: .value("Band", Format.frequency(b.center)), y: .value("Seconds", b.t20))
                        .foregroundStyle(b.t20 > 0.6 ? Theme.coral : Theme.orchid)
                        .cornerRadius(4)
                }
                .frame(height: 160)
            }
        }
    }

    // MARK: Diagnostics

    private func diagnostics(_ p: ProgramResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Measurement quality").font(.headlineRounded).foregroundStyle(.white)
                row("Bluetooth delay", String(format: "%.0f ms", p.latency * 1000))
                row("Clock drift", String(format: "%.0f ppm", p.driftPPM))
                row("Room noise", String(format: "%.0f dBFS", p.noiseFloorDBFS))
                row("Peak input", String(format: "%.0f dBFS", 20 * log10(max(p.peakInputLevel, 1e-6))))
                if let l = p.sweep(.left), let r = p.sweep(.right) {
                    row("Right vs left arrival", String(format: "%+.1f ms", (r.arrival - l.arrival) * 1000))
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.mist)
            Spacer()
            Text(v).foregroundStyle(.white).monospacedDigit()
        }
        .font(.subheadline)
    }
}

struct ResponseChart: View {
    let summary: ResponseSummary
    let smoothing: Double
    let showSeats: Bool
    let reference: Double?

    struct Point: Identifiable {
        var id: String { "\(series)-\(f)" }
        var series: String
        var f: Double
        var db: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        let avg = summary.average.smoothed(fraction: smoothing)
        let ref = reference ?? avg.meanLevel(in: 200...2_000)
        let stride = 2
        for i in Swift.stride(from: 0, to: avg.frequencies.count, by: stride) where avg.frequencies[i] >= 15 {
            out.append(Point(series: "Average", f: avg.frequencies[i], db: avg.db[i] - ref))
        }
        if showSeats {
            for (s, seat) in summary.perSeat.enumerated() where summary.perSeat.count > 1 {
                let sm = seat.smoothed(fraction: smoothing)
                for i in Swift.stride(from: 0, to: sm.frequencies.count, by: stride * 2) where sm.frequencies[i] >= 15 {
                    out.append(Point(series: "Seat \(s + 1)", f: sm.frequencies[i], db: sm.db[i] - ref))
                }
            }
        }
        return out
    }

    private var unreliableRanges: [(Double, Double)] {
        var ranges: [(Double, Double)] = []
        var start: Double?
        for (i, ok) in summary.reliable.enumerated() {
            let f = summary.average.frequencies[i]
            if !ok && start == nil { start = f }
            if ok, let s = start { ranges.append((s, f)); start = nil }
        }
        if let s = start, let last = summary.average.frequencies.last { ranges.append((s, last)) }
        return ranges.filter { $0.1 > 15 }
    }

    var body: some View {
        Chart {
            ForEach(Array(unreliableRanges.enumerated()), id: \.offset) { _, r in
                RectangleMark(xStart: .value("f", max(r.0, 15)), xEnd: .value("f", r.1), yStart: .value("dB", -24), yEnd: .value("dB", 18))
                    .foregroundStyle(Color.white.opacity(0.06))
            }
            RuleMark(y: .value("Target", 0)).foregroundStyle(Theme.aurora.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(points) { p in
                LineMark(x: .value("Frequency", p.f), y: .value("dB", p.db), series: .value("Series", p.series))
                    .foregroundStyle(p.series == "Average" ? Theme.lumen : Theme.orchid.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: p.series == "Average" ? 2.2 : 1))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 15...20_000, type: .log)
        .chartYScale(domain: -24...18)
        .chartXAxis {
            AxisMarks(values: [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]) { v in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel { if let f = v.as(Double.self) { Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))") } }
            }
        }
        .chartYAxis {
            AxisMarks(values: [-18, -12, -6, 0, 6, 12]) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel()
            }
        }
        .accessibilityLabel("Frequency response chart")
    }
}
