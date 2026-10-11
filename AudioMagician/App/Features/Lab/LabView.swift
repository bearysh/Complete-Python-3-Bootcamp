import SwiftUI
import Charts
import AVFoundation
import SignalKit

/// M0 spike tool. Checks the risky assumptions on real hardware:
/// A2DP + built-in mic in measurement mode, sweep deconvolution through
/// Bluetooth, drift correction, and run-to-run repeatability.
struct LabView: View {
    @Environment(AppModel.self) private var model
    @State private var runner = SweepRunner()
    @State private var results: [ProgramResult] = []
    @State private var running = false
    @State private var runsWanted = 1
    @State private var exportURL: URL?
    @State private var log: [String] = []

    var body: some View {
        List {
            Section("Audio route") {
                let r = model.audio.route
                LabeledContent("Output", value: r.outputName)
                LabeledContent("Output is A2DP", value: r.outputIsA2DP ? "Yes" : "No")
                LabeledContent("HFP detected", value: r.outputIsHFP ? "Yes ⚠️" : "No")
                LabeledContent("Input is built-in mic", value: r.inputIsBuiltInMic ? "Yes" : "No")
                LabeledContent("Mic data source", value: r.inputDataSource ?? "—")
                LabeledContent("Sample rate", value: String(format: "%.0f Hz", r.sampleRate))
                LabeledContent("Reported output latency", value: String(format: "%.0f ms", r.outputLatency * 1000))
                Button("Activate & refresh") { try? model.audio.activate() }
            }

            Section("Sweeps") {
                Stepper("Runs: \(runsWanted)", value: $runsWanted, in: 1...10)
                Button(running ? "Running…" : "Run \(runsWanted == 1 ? "sweep" : "\(runsWanted) sweeps")") { Task { await run() } }
                    .disabled(running)
                if running { ProgressView(value: runner.progress) }
                if case .problem(let msg) = runner.phase { Text(msg).foregroundStyle(Theme.coral).font(.footnote) }
            }

            if let last = results.last {
                Section("Last run") {
                    LabeledContent("Latency (BT + acoustic)", value: String(format: "%.1f ms", last.latency * 1000))
                    LabeledContent("Clock drift", value: String(format: "%.1f ppm", last.driftPPM))
                    LabeledContent("Noise floor", value: String(format: "%.1f dBFS", last.noiseFloorDBFS))
                    LabeledContent("Peak input", value: String(format: "%.1f dBFS", 20 * log10(max(last.peakInputLevel, 1e-9))))
                    ForEach(last.sweeps, id: \.channel) { s in
                        LabeledContent("SNR \(s.channel.rawValue) @1 kHz", value: String(format: "%.0f dB", s.response.value(at: 1_000) - s.noiseFloor.value(at: 1_000)))
                    }
                    if let l = last.sweep(.left), let r = last.sweep(.right) {
                        LabeledContent("R − L arrival", value: String(format: "%+.2f ms", (r.arrival - l.arrival) * 1000))
                    }
                    LabChart(result: last).frame(height: 220)
                }
            }

            if results.count > 1 {
                Section("Repeatability (100 Hz – 10 kHz, 1/6 oct, L+R)") {
                    let (maxDev, rms) = repeatability()
                    LabeledContent("Max deviation", value: String(format: "±%.2f dB", maxDev))
                    LabeledContent("RMS deviation", value: String(format: "%.2f dB", rms))
                    Text(maxDev <= 0.5 ? "✅ Meets the M0 target (±0.5 dB)." : "⚠️ Above the ±0.5 dB M0 target.")
                        .font(.footnote)
                    LabeledContent("Drift range", value: String(format: "%.1f … %.1f ppm", results.map(\.driftPPM).min() ?? 0, results.map(\.driftPPM).max() ?? 0))
                }
            }

            if !results.isEmpty {
                Section("Export") {
                    Button("Prepare export (JSON)") { exportURL = export() }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share results", systemImage: "square.and.arrow.up") }
                    }
                }
            }

            if !log.isEmpty {
                Section("Log") {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Measurement lab")
        .onAppear { try? model.audio.activate() }
    }

    private func run() async {
        running = true
        defer { running = false }
        try? model.audio.activate()
        for i in 1...runsWanted {
            log.append("Run \(i) started \(Date().formatted(date: .omitted, time: .standard))")
            if let r = await runner.measure() {
                results.append(r)
                log.append(String(format: "Run %d ok: latency %.1f ms, drift %.1f ppm", i, r.latency * 1000, r.driftPPM))
            } else {
                log.append("Run \(i) failed")
            }
        }
    }

    /// Deviation of each run's L+R response from the mean of all runs.
    private func repeatability() -> (Double, Double) {
        let curves = results.compactMap { $0.sweep(.both)?.response.smoothed(fraction: 6) }
        guard let avg = Smoothing.average(curves)?.mean else { return (0, 0) }
        var maxDev = 0.0, sumSq = 0.0, n = 0.0
        for c in curves {
            for (i, f) in c.frequencies.enumerated() where f >= 100 && f <= 10_000 {
                let d = abs(c.db[i] - avg.db[i])
                maxDev = max(maxDev, d)
                sumSq += d * d
                n += 1
            }
        }
        return (maxDev, n > 0 ? sqrt(sumSq / n) : 0)
    }

    private func export() -> URL? {
        struct Export: Encodable {
            var device: String
            var route: String
            var date: Date
            var results: [ProgramResult]
        }
        let e = Export(device: model.deviceModel, route: model.audio.route.outputName, date: .now, results: results)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(e) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-magician-lab-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url)
        return url
    }
}

struct LabChart: View {
    let result: ProgramResult

    struct P: Identifiable {
        var id: String { "\(c)\(f)" }
        var c: String
        var f: Double
        var db: Double
    }

    var body: some View {
        let pts: [P] = result.sweeps.flatMap { s -> [P] in
            let r = s.response.smoothed(fraction: 6)
            return stride(from: 0, to: r.frequencies.count, by: 4).compactMap { i in
                r.frequencies[i] >= 15 ? P(c: s.channel.rawValue, f: r.frequencies[i], db: r.db[i]) : nil
            }
        }
        Chart(pts) { p in
            LineMark(x: .value("Hz", p.f), y: .value("dB", p.db), series: .value("ch", p.c))
                .foregroundStyle(by: .value("ch", p.c))
        }
        .chartXScale(domain: 15...20_000, type: .log)
    }
}
