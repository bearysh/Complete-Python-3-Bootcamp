import Foundation
import SignalKit
import ReceiverKit
import RoomAnalysis

public struct PlanStep: Codable, Sendable, Equatable, Identifiable {
    public enum Group: String, Codable, Sendable, CaseIterable {
        case roomCorrection, levels, distances, crossover, subwoofer, eq, placement, room

        public var title: String {
            switch self {
            case .roomCorrection: "Room correction"
            case .levels: "Speaker levels"
            case .distances: "Speaker distances"
            case .crossover: "Crossover"
            case .subwoofer: "Subwoofer"
            case .eq: "Equalizer"
            case .placement: "Placement"
            case .room: "Your room"
            }
        }
    }

    public var id: String
    public var group: Group
    public var title: String
    /// Plain-language reason, shown under "Why?".
    public var why: String
    /// The receiver setting to change. Nil for advice-only steps.
    public var guide: GuideStep?
    /// Free-text advice (placement, furnishings…).
    public var advice: String?
    /// Worth trying, then re-measuring to confirm.
    public var tryThenCheck: Bool

    /// Receiver settings are part of the paid unlock; advice is free.
    public var requiresUnlock: Bool { guide != nil }
}

public struct TuningPlan: Codable, Sendable, Equatable {
    public var steps: [PlanStep]
    /// Things we deliberately didn't recommend, and why (e.g. "needs calibration").
    public var limitations: [String]

    public var settingSteps: [PlanStep] { steps.filter { $0.guide != nil } }
    public var adviceSteps: [PlanStep] { steps.filter { $0.guide == nil } }
}

/// Converts findings into receiver steps, fitted to the receiver's controls.
public struct TuningPlanner: Sendable {
    public var profile: ReceiverProfile

    public init(profile: ReceiverProfile) {
        self.profile = profile
    }

    public func plan(for data: SessionData, analysis: AnalysisResult) -> TuningPlan {
        let guide = ManualGuideController(profile: profile)
        var steps: [PlanStep] = []
        var limitations: [String] = []
        let setup = data.setup
        let keepCorrection = setup.correction == .keep
        let correctionName = profile.roomCorrectionSystems.first ?? "room correction"

        if !keepCorrection, !profile.roomCorrectionSystems.isEmpty {
            steps.append(settingStep(.roomCorrection, guide.step(for: .roomCorrection(enabled: false)),
                                     why: "We're tuning by hand, so \(correctionName) should be off. Otherwise both would try to fix the same things."))
        }

        // Levels: changes relative to where each level is set now.
        for f in analysis.findings {
            guard case let .levelOffset(ch, dB) = f.kind else { continue }
            let range = profile.levelRange(for: ch)
            let change = range.quantize(-dB)
            guard change != 0 else { continue }
            var g = guide.step(for: .level(ch, dB: change))
            g.valueText = change < 0 ? "Lower by \(Format.signedDB(-change).dropFirst())" : "Raise by \(Format.signedDB(change).dropFirst())"
            let louder = dB > 0
            steps.append(settingStep(.levels, g, why: "\(ch.displayName) is about \(String(format: "%.1f", abs(dB))) dB \(louder ? "louder" : "quieter") than your front speakers. Matching levels keeps voices and effects anchored where they belong."))
        }
        if analysis.findings.contains(where: { $0.kind == .subLevelNeedsCalibration }) {
            limitations.append("Subwoofer level needs a calibrated microphone for deep bass. It's coming for your iPhone in a future update.")
        }

        // Distances: straight from the user's measurements.
        for ch in setup.layout.channels {
            guard let m = setup.distances[ch] else { continue }
            let value = profile.distance.quantize(m)
            steps.append(settingStep(.distances, guide.step(for: .distance(ch, meters: value)),
                                     why: "Telling the receiver how far each speaker is lets it time every speaker to arrive together at your seat."))
        }
        if setup.distances.isEmpty {
            limitations.append("Add your speaker distances (by hand or with the camera) to get distance settings.")
        }

        // Crossover and sub blend.
        if setup.layout.hasSubwoofer {
            let gap = analysis.findings.compactMap { f -> (Double, Double)? in
                if case let .crossoverGap(fq, d) = f.kind { return (fq, d) }
                return nil
            }.first
            let base = profile.nearestCrossover(to: setup.speakerSize.suggestedCrossover)
            steps.append(settingStep(.crossover, guide.step(for: .crossover(base)),
                                     why: "Sends deep bass to the subwoofer, which is built for it, and lets your \(setup.speakerSize.displayName.lowercased()) play cleaner and louder."))
            if let gap {
                let (fq, depth) = gap
                var g = guide.step(for: .subwooferPhase(inverted: true))
                g.valueText = "Try 180°"
                steps.append(PlanStep(
                    id: "sub-phase", group: .subwoofer, title: "Flip the subwoofer phase",
                    why: "Around \(Format.frequency(fq)) your sub and speakers partly cancel each other (a \(Int(depth.rounded())) dB hole). Flipping phase often fills it in. Re-check afterwards and keep whichever sounds fuller.",
                    guide: g, advice: nil, tryThenCheck: true))
            }
        }

        // EQ: only with a calibrated mic, only if the receiver allows it in this mode.
        if !analysis.calibrated {
            limitations.append("EQ advice needs your iPhone's microphone calibration, which is coming in a future update. Levels and distances are fully accurate today.")
        } else if keepCorrection && !profile.eq.availableWithRoomCorrection {
            limitations.append("\(correctionName) is handling EQ, so we've left it alone. We've only fine-tuned what sits on top of it.")
        } else if profile.eq.kind == .graphic {
            steps += eqSteps(analysis: analysis, guide: guide, crossover: setup.layout.hasSubwoofer ? profile.nearestCrossover(to: setup.speakerSize.suggestedCrossover) : nil)
        }

        steps += adviceSteps(analysis)
        return TuningPlan(steps: steps, limitations: limitations)
    }

    func settingStep(_ group: PlanStep.Group, _ g: GuideStep, why: String) -> PlanStep {
        PlanStep(id: g.id, group: group, title: g.title, why: why, guide: g, advice: nil, tryThenCheck: false)
    }

    // MARK: EQ

    /// Desired cut curve on a coarse grid: cut only where the measurement is
    /// reliable and agrees across seats; leave everything else at 0.
    static func desiredCuts(_ r: ResponseSummary, reference: Double, modalLimit: Double = 300, maxBroadCut: Double = 3, range: ClosedRange<Double>) -> (FrequencyResponse, [Double]) {
        let grid = LogGrid.make(from: max(20, range.lowerBound), to: min(16_000, range.upperBound), pointsPerOctave: 12)
        let fine = r.average.smoothed(fraction: 6)
        let broad = r.average.smoothed(fraction: 1)
        var d = [Double](repeating: 0, count: grid.count)
        var w = [Double](repeating: 0.3, count: grid.count)
        let fr = r.average.frequencies
        for (i, f) in grid.enumerated() {
            // Nearest grid point in the measurement for reliability / spread.
            let j = fr.indices.min { abs(log(fr[$0] / f)) < abs(log(fr[$1] / f)) } ?? 0
            guard r.reliable[j], r.spreadDB[j] <= 4 else { continue }
            if f <= modalLimit {
                d[i] = min(0, reference - fine.value(at: f))
            } else {
                d[i] = max(-maxBroadCut, min(0, reference - broad.value(at: f)))
            }
            w[i] = 1
        }
        return (FrequencyResponse(frequencies: grid, db: d), w)
    }

    func eqSteps(analysis: AnalysisResult, guide: ManualGuideController, crossover: Double?) -> [PlanStep] {
        guard let ref = analysis.referenceLevel else { return [] }
        var out: [PlanStep] = []
        let eq = profile.eq
        // Main speakers from their own sweeps (above the crossover when a sub handles the bass).
        let mains: [(SpeakerChannel, SweepChannel)] = [(.frontLeft, .left), (.frontRight, .right)]
        for (ch, sweep) in mains {
            guard let r = analysis.response(sweep) else { continue }
            let low = crossover.map { $0 * 0.8 } ?? 20
            let (desired, weights) = Self.desiredCuts(r, reference: ref, range: low...16_000)
            let gains = EQFitter.fitGraphic(desired: desired, weights: weights, bands: eq.bands, gain: eq.gain, q: eq.bandQ)
            out += bandSteps(ch, bands: eq.bands, gains: gains, guide: guide)
        }
        // Subwoofer bands from the combined response below the crossover.
        if let xo = crossover, !eq.subwooferBands.isEmpty, let r = analysis.response(.both) {
            let (desired, weights) = Self.desiredCuts(r, reference: ref, range: 20...(xo * 1.25))
            let gains = EQFitter.fitGraphic(desired: desired, weights: weights, bands: eq.subwooferBands, gain: eq.gain, q: eq.bandQ)
            out += bandSteps(.subwoofer, bands: eq.subwooferBands, gains: gains, guide: guide)
        }
        return out
    }

    func bandSteps(_ ch: SpeakerChannel, bands: [Double], gains: [Double], guide: ManualGuideController) -> [PlanStep] {
        zip(bands, gains).compactMap { f, g in
            guard g < 0 else { return nil }
            return settingStep(.eq, guide.step(for: .eqBand(ch, frequency: f, gainDB: g)),
                               why: "Tames a build-up of sound around \(Format.frequency(f)) at your seats. We only ever cut; boosting a dip wastes power and rarely works.")
        }
    }

    // MARK: Advice (free)

    func adviceSteps(_ analysis: AnalysisResult) -> [PlanStep] {
        var out: [PlanStep] = []
        for f in analysis.findings {
            switch f.kind {
            case let .bassDip(fq, depth, varies):
                if varies {
                    out.append(PlanStep(id: "advice-\(f.id)", group: .placement, title: "A bass hole that moves with you",
                                        why: "Around \(Format.frequency(fq)) the bass drops by about \(Int(depth.rounded())) dB, and it changes from seat to seat. That's the room's shape, not your speakers, so EQ can't fill it.",
                                        guide: nil, advice: "Try moving the subwoofer about 30–60 cm along the front wall, or moving your sofa slightly forward or back, then measure again.", tryThenCheck: true))
                } else {
                    out.append(PlanStep(id: "advice-\(f.id)", group: .placement, title: "A steady bass hole",
                                        why: "Around \(Format.frequency(fq)) the bass drops by about \(Int(depth.rounded())) dB at every seat. This usually comes from sound bouncing off a nearby wall and cancelling itself.",
                                        guide: nil, advice: "Pull the speakers or subwoofer a little further from the wall behind them (or closer, right up to it), then measure again.", tryThenCheck: true))
                }
            case let .longDecay(t):
                out.append(PlanStep(id: "advice-decay", group: .room, title: "Soften the echo",
                                    why: "Sound lingers for about \(String(format: "%.1f", t)) seconds, which can blur dialogue.",
                                    guide: nil, advice: "A rug between you and the speakers, curtains, or a bookshelf on a bare wall will make voices clearer.", tryThenCheck: false))
            case .lowSignal:
                out.append(PlanStep(id: "advice-signal", group: .room, title: "Measure a little louder",
                                    why: "Parts of the sound were too close to the room's background noise to judge.",
                                    guide: nil, advice: "Turn the volume up a few steps or switch off fans and appliances, then measure again for more complete results.", tryThenCheck: false))
            default:
                break
            }
        }
        return out
    }
}
