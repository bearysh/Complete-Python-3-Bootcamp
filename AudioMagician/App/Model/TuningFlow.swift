import Foundation
import Observation
import SignalKit
import Calibration
import ReceiverKit
import RoomAnalysis
import Recommendations

enum TuningStep: Hashable {
    case speakers, correction, distances, connect, checklist, placement, quiet, volume
    case sweeps, tones, seats, analyzing, results, details, plan, verify
}

/// One tuning session, from setup to fix plan. Drives the NavigationStack.
@MainActor
@Observable
final class TuningFlow {
    var path: [TuningStep] = []

    let profile: ReceiverProfile
    let capability: MeasurementCapability
    var roomName = "Living room"
    var setup: RoomSetup

    // Measurements
    var seats: [SeatMeasurement] = []
    var tones: [ToneReading] = []
    var plannedSeats = 3
    /// Band level of the quiet room, per tone band, from the quiet check.
    var quietLevels: [ClosedRange<Double>: Double] = [:]
    var quietBroadbandDB: Double = -80

    // Results
    var analysis: AnalysisResult?
    var plan: TuningPlan?
    var savedRecord: TuningRecord?

    // Verify
    var verifySeat: SeatMeasurement?
    var verifyTones: [ToneReading] = []

    /// Read-only mode when re-opening a past result.
    let isReview: Bool

    init(profile: ReceiverProfile, capability: MeasurementCapability) {
        self.profile = profile
        self.capability = capability
        setup = RoomSetup(receiverID: profile.id, layout: SpeakerLayout.presets[2])
        isReview = false
    }

    init(review record: TuningRecord, profile: ReceiverProfile, capability: MeasurementCapability) {
        self.profile = profile
        self.capability = capability
        isReview = true
        let session = record.session
        setup = session?.setup ?? RoomSetup(receiverID: profile.id, layout: SpeakerLayout.presets[2])
        seats = session?.seats ?? []
        tones = session?.tones ?? []
        analysis = record.analysis
        plan = record.plan
        savedRecord = record
        if let name = record.room?.name { roomName = name }
    }

    var calibrated: Bool { capability.isCalibrated }

    var session: SessionData {
        SessionData(setup: setup, seats: seats, tones: tones, currentCrossover: nil)
    }

    /// Channels to level-match, in the receiver's test-tone order.
    var toneChannels: [SpeakerChannel] {
        profile.testToneOrder.filter { setup.layout.channels.contains($0) }
    }

    func go(_ step: TuningStep) { path.append(step) }

    /// Where to go after `step`, depending on what this phone can measure.
    func next(after step: TuningStep) -> TuningStep {
        switch step {
        case .speakers: .correction
        case .correction: .distances
        case .distances: .connect
        case .connect: .checklist
        case .checklist: .placement
        case .placement: .quiet
        case .quiet: .volume
        case .volume: calibrated ? .sweeps : .tones
        case .sweeps: .tones
        case .tones: calibrated && plannedSeats > 1 ? .seats : .analyzing
        case .seats: .analyzing
        case .analyzing: .results
        case .results: .plan
        case .details: .plan
        case .plan: .verify
        case .verify: .results
        }
    }

    func advance(from step: TuningStep) { go(next(after: step)) }

    /// Runs analysis and planning off the main thread.
    func analyze() async {
        let data = session
        let cap = capability
        let profile = profile
        let (a, p) = await Task.detached(priority: .userInitiated) {
            let a = RoomAnalyzer(capability: cap).analyze(data)
            let p = TuningPlanner(profile: profile).plan(for: data, analysis: a)
            return (a, p)
        }.value
        analysis = a
        plan = p
    }
}
