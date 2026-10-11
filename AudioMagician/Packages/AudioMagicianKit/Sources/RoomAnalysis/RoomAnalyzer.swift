import Foundation
import SignalKit
import Calibration
import ReceiverKit

/// Turns raw measurements into findings. Pure and deterministic.
public struct RoomAnalyzer: Sendable {
    public struct Thresholds: Sendable {
        /// Minimum SNR for a frequency to count as measured.
        public var minSNR: Double = 15
        /// Level offsets smaller than this aren't worth a step (receiver steps are 0.5 dB).
        public var minLevelOffset: Double = 1.0
        /// Bass peak must exceed the reference by this much.
        public var minPeakExcess: Double = 3
        public var minDipDepth: Double = 6
        /// Seat-to-seat spread above which a dip is considered position-dependent.
        public var positionDependentSpread: Double = 4
        /// Upper limit of the room-mode region (roughly the Schroeder frequency of a living room).
        public var modalLimit: Double = 300
        public var lowestFrequency: Double = 20
        public var longDecay: Double = 0.6
        public init() {}
    }

    public var thresholds: Thresholds
    public var capability: MeasurementCapability

    public init(capability: MeasurementCapability, thresholds: Thresholds = Thresholds()) {
        self.capability = capability
        self.thresholds = thresholds
    }

    public func analyze(_ data: SessionData) -> AnalysisResult {
        var findings: [Finding] = []
        findings += levelFindings(data)

        var responses: [ResponseSummary] = []
        var reference: Double?
        var decay: [DecayBand] = []
        if capability.isCalibrated, !data.seats.isEmpty {
            responses = SweepChannel.allCases.compactMap { summarize($0, seats: data.seats) }
            if let both = responses.first(where: { $0.channel == .both }) ?? responses.first {
                let ref = both.average.smoothed(fraction: 1).meanLevel(in: 200...2_000)
                reference = ref
                findings += bassFindings(both, reference: ref, seats: data.seats.count)
                findings += tonalFindings(both, reference: ref)
                if data.setup.layout.hasSubwoofer {
                    let xo = data.currentCrossover ?? data.setup.speakerSize.suggestedCrossover
                    findings += crossoverFindings(both, reference: ref, crossover: xo, existing: findings)
                }
                let unreliable = fractionUnreliable(both, in: 30...10_000)
                if unreliable > 0.2 {
                    findings.append(Finding(id: "low-signal", kind: .lowSignal(fractionUnreliable: unreliable), severity: unreliable > 0.5 ? .significant : .noticeable, confidence: 1))
                }
            }
            decay = averageDecay(data.seats)
            if let mid = decay.first(where: { $0.center == 500 }).map(\.t20), let k = decay.first(where: { $0.center == 1_000 }).map(\.t20) {
                let t = (mid + k) / 2
                if t > thresholds.longDecay {
                    findings.append(Finding(id: "long-decay", kind: .longDecay(seconds: t), severity: t > 0.9 ? .significant : .noticeable, confidence: 0.8))
                }
            }
        }

        findings.sort { ($0.severity, $0.confidence) > ($1.severity, $1.confidence) }
        return AnalysisResult(
            findings: findings,
            responses: responses,
            referenceLevel: reference,
            decay: decay,
            tones: data.tones,
            score: score(findings),
            calibrated: capability.isCalibrated
        )
    }

    // MARK: Levels

    func levelFindings(_ data: SessionData) -> [Finding] {
        guard !data.tones.isEmpty else { return [] }
        var levels: [SpeakerChannel: Double] = [:]
        for t in data.tones {
            var l = t.levelDB
            if let cal = capability.calibration { l -= Self.meanCorrection(cal, band: t.band) }
            levels[t.channel] = l
        }
        let fronts = [SpeakerChannel.frontLeft, .frontRight].compactMap { levels[$0] }
        let speakers = levels.filter { !$0.key.isSubwoofer }.map(\.value)
        let refSource = fronts.isEmpty ? speakers : fronts
        guard !refSource.isEmpty else { return [] }
        let ref = 10 * log10(refSource.reduce(0) { $0 + pow(10, $1 / 10) } / Double(refSource.count))

        var out: [Finding] = []
        for (ch, l) in levels.sorted(by: { $0.key < $1.key }) {
            if ch.isSubwoofer && !capability.isCalibrated {
                out.append(Finding(id: "sub-level-cal", kind: .subLevelNeedsCalibration, severity: .gentle, confidence: 1))
                continue
            }
            let offset = l - ref
            guard abs(offset) >= thresholds.minLevelOffset else { continue }
            out.append(Finding(
                id: "level-\(ch.rawValue)",
                kind: .levelOffset(ch, dB: offset),
                severity: .from(magnitude: abs(offset), noticeable: 2, significant: 4),
                confidence: ch.isSubwoofer ? 0.7 : 0.9
            ))
        }
        return out
    }

    static func meanCorrection(_ cal: MicCalibration, band: ClosedRange<Double>) -> Double {
        let fs = LogGrid.make(from: band.lowerBound, to: band.upperBound, pointsPerOctave: 6)
        return fs.map { cal.correction(at: $0) }.reduce(0, +) / Double(max(fs.count, 1))
    }

    // MARK: Responses

    func summarize(_ channel: SweepChannel, seats: [SeatMeasurement]) -> ResponseSummary? {
        let sweeps = seats.compactMap { $0.program.sweep(channel) }
        guard !sweeps.isEmpty, let cal = capability.calibration else { return nil }
        let perSeat = sweeps.map { cal.apply(to: $0.response) }
        guard let avg = Smoothing.average(perSeat) else { return nil }
        let noise = sweeps.map { cal.apply(to: $0.noiseFloor) }
        var worstNoise = noise[0].db
        for n in noise.dropFirst() { worstNoise = zip(worstNoise, n.db).map { max($0, $1) } }
        let grid = avg.mean.frequencies
        var reliable = [Bool](repeating: true, count: grid.count)
        for s in sweeps {
            for (i, snr) in s.snrDB.enumerated() where snr < thresholds.minSNR { reliable[i] = false }
        }
        return ResponseSummary(
            channel: channel,
            average: avg.mean,
            spreadDB: avg.spreadDB,
            perSeat: perSeat,
            noiseFloor: FrequencyResponse(frequencies: grid, db: worstNoise),
            reliable: reliable
        )
    }

    func fractionUnreliable(_ r: ResponseSummary, in band: ClosedRange<Double>) -> Double {
        let idx = r.average.frequencies.indices.filter { band.contains(r.average.frequencies[$0]) }
        guard !idx.isEmpty else { return 0 }
        return Double(idx.filter { !r.reliable[$0] }.count) / Double(idx.count)
    }

    // MARK: Bass

    func bassFindings(_ r: ResponseSummary, reference ref: Double, seats: Int) -> [Finding] {
        let smooth = r.average.smoothed(fraction: 6)
        let f = smooth.frequencies
        let excess = smooth.db.map { $0 - ref }
        let region = f.indices.filter { f[$0] >= thresholds.lowestFrequency && f[$0] <= thresholds.modalLimit && r.reliable[$0] }
        guard region.count > 3 else { return [] }

        var out: [Finding] = []
        var peaks: [(i: Int, ex: Double)] = []
        var dips: [(i: Int, ex: Double)] = []
        for i in region where i > 0 && i < f.count - 1 {
            if excess[i] >= excess[i - 1], excess[i] > excess[i + 1], excess[i] >= thresholds.minPeakExcess { peaks.append((i, excess[i])) }
            if excess[i] <= excess[i - 1], excess[i] < excess[i + 1], excess[i] <= -thresholds.minDipDepth { dips.append((i, excess[i])) }
        }

        for p in peaks.sorted(by: { $0.ex > $1.ex }).prefix(5) {
            // Width where the excess falls to half its peak value (in dB).
            let half = p.ex / 2
            var lo = p.i, hi = p.i
            while lo > 0 && excess[lo] > half { lo -= 1 }
            while hi < f.count - 1 && excess[hi] > half { hi += 1 }
            let q = min(10, max(1, f[p.i] / max(f[hi] - f[lo], 1e-6)))
            let affected = r.perSeat.filter { $0.smoothed(fraction: 6).value(at: f[p.i]) - ref > p.ex * 0.4 }.count
            let agreement = Double(affected) / Double(max(seats, 1))
            out.append(Finding(
                id: "peak-\(Int(f[p.i]))",
                kind: .bassPeak(frequency: f[p.i], excessDB: p.ex, q: q, seatsAffected: affected, seatsTotal: seats),
                severity: .from(magnitude: p.ex, noticeable: 5, significant: 8),
                confidence: min(1, 0.4 + 0.6 * agreement)
            ))
        }
        for d in dips.sorted(by: { $0.ex < $1.ex }).prefix(3) {
            let varies = r.spreadDB[d.i] > thresholds.positionDependentSpread
            out.append(Finding(
                id: "dip-\(Int(f[d.i]))",
                kind: .bassDip(frequency: f[d.i], depthDB: -d.ex, changesBetweenSeats: varies),
                severity: .from(magnitude: -d.ex, noticeable: 8, significant: 12),
                confidence: varies ? 0.6 : 0.85
            ))
        }
        return out
    }

    func crossoverFindings(_ r: ResponseSummary, reference ref: Double, crossover xo: Double, existing: [Finding]) -> [Finding] {
        let smooth = r.average.smoothed(fraction: 6)
        let band = (xo / 1.6)...(xo * 1.6)
        let idx = smooth.frequencies.indices.filter { band.contains(smooth.frequencies[$0]) && r.reliable[$0] }
        guard let worst = idx.min(by: { smooth.db[$0] < smooth.db[$1] }) else { return [] }
        let depth = ref - smooth.db[worst]
        guard depth >= thresholds.minDipDepth, r.spreadDB[worst] <= thresholds.positionDependentSpread else { return [] }
        return [Finding(
            id: "crossover-gap",
            kind: .crossoverGap(frequency: smooth.frequencies[worst], depthDB: depth),
            severity: .from(magnitude: depth, noticeable: 6, significant: 10),
            confidence: 0.7
        )]
    }

    func tonalFindings(_ r: ResponseSummary, reference ref: Double) -> [Finding] {
        let broad = r.average.smoothed(fraction: 1)
        var out: [Finding] = []
        for band in [300.0...1_000, 1_000...4_000, 4_000...10_000] {
            let idx = broad.frequencies.indices.filter { band.contains(broad.frequencies[$0]) }
            guard !idx.isEmpty, idx.allSatisfy({ r.reliable[$0] }) else { continue }
            let level = broad.meanLevel(in: band) - ref
            if level >= 3 {
                out.append(Finding(id: "tilt-\(Int(band.lowerBound))", kind: .tonalTilt(band: band, excessDB: level), severity: .from(magnitude: level, noticeable: 3, significant: 5), confidence: 0.6))
            }
        }
        return out
    }

    func averageDecay(_ seats: [SeatMeasurement]) -> [DecayBand] {
        let bands = seats.compactMap { $0.program.sweep(.both)?.decay ?? $0.program.sweeps.first?.decay }.flatMap { $0 }
        return Decay.octaveCenters.compactMap { c -> DecayBand? in
            let m = bands.filter { $0.center == c }
            guard !m.isEmpty else { return nil }
            let n = Double(m.count)
            return DecayBand(center: c, t20: m.map(\.t20).reduce(0, +) / n, edt: m.map(\.edt).reduce(0, +) / n)
        }
    }

    // MARK: Score

    func score(_ findings: [Finding]) -> Int {
        var s = 100.0
        for f in findings {
            switch f.kind {
            case let .levelOffset(_, dB): s -= min(10, abs(dB) * 2)
            case let .bassPeak(_, ex, _, _, _): s -= min(15, ex * 1.5) * f.confidence
            case let .bassDip(_, d, _): s -= min(10, d * 0.6)
            case let .crossoverGap(_, d): s -= min(12, d)
            case let .tonalTilt(_, ex): s -= min(8, ex * 1.5)
            case let .longDecay(t): s -= min(10, (t - 0.4) * 20)
            case .lowSignal, .subLevelNeedsCalibration: break
            }
        }
        return Int(max(20, min(100, s)).rounded())
    }
}
