import XCTest
import SignalKit
import Calibration
import ReceiverKit
import RoomAnalysis
@testable import Recommendations

final class RecommendationsTests: XCTestCase {
    var profile: ReceiverProfile { ProfileLibrary.profile(id: "onkyo-tx-rz50")! }
    let grid = LogGrid.standard

    func testGraphicFitCutsPeakAndNeverBoosts() {
        // Desired: a 6 dB cut centred on 63 Hz, zero elsewhere.
        let f = LogGrid.make(from: 20, to: 16_000, pointsPerOctave: 12)
        let desired = FrequencyResponse(frequencies: f, db: f.map { -6 * exp(-pow(log2($0 / 63) / 0.25, 2)) })
        let w = f.map { _ in 1.0 }
        let gains = EQFitter.fitGraphic(desired: desired, weights: w, bands: profile.eq.bands, gain: profile.eq.gain, q: profile.eq.bandQ)
        XCTAssertEqual(gains.count, profile.eq.bands.count)
        XCTAssertTrue(gains.allSatisfy { $0 <= 0 }, "\(gains)")
        let i63 = profile.eq.bands.firstIndex(of: 63)!
        XCTAssertLessThanOrEqual(gains[i63], -3)
        let i1k = profile.eq.bands.firstIndex(of: 1_000)!
        XCTAssertEqual(gains[i1k], 0)
        // Whole-dB steps on the RZ50.
        XCTAssertTrue(gains.allSatisfy { $0 == $0.rounded() })
    }

    func testParametricFitPlacesCutOnPeak() {
        let f = LogGrid.make(from: 20, to: 500, pointsPerOctave: 24)
        let desired = FrequencyResponse(frequencies: f, db: f.map { -8 * exp(-pow(log2($0 / 45) / 0.15, 2)) })
        let filters = EQFitter.fitParametric(desired: desired, weights: f.map { _ in 1 }, maxFilters: 3, gain: ControlRange(min: -12, max: 0, step: 0.5, unit: "dB"))
        let first = try! XCTUnwrap(filters.first)
        XCTAssertEqual(first.frequency, 45, accuracy: 3)
        XCTAssertEqual(first.gainDB, -8, accuracy: 0.6)
    }

    func testLevelsOnlyPlan() {
        var setup = RoomSetup(receiverID: profile.id, layout: SpeakerLayout.presets[2], correction: .turnOff)
        setup.distances = [.frontLeft: 3.1, .center: 2.9]
        let tones = [
            ToneReading(channel: .frontLeft, levelDB: -30, band: 250...4_000),
            ToneReading(channel: .frontRight, levelDB: -30, band: 250...4_000),
            ToneReading(channel: .center, levelDB: -32, band: 250...4_000),
        ]
        let data = SessionData(setup: setup, tones: tones)
        let analysis = RoomAnalyzer(capability: .levelsOnly).analyze(data)
        let plan = TuningPlanner(profile: profile).plan(for: data, analysis: analysis)

        XCTAssertEqual(plan.steps.first?.id, "room-correction")
        let level = plan.steps.first { $0.id == "level-center" }
        XCTAssertEqual(level?.guide?.change, .level(.center, dB: 2))
        XCTAssertEqual(level?.guide?.valueText, "Raise by 2 dB")
        XCTAssertNotNil(plan.steps.first { $0.id == "distance-frontLeft" })
        XCTAssertFalse(plan.steps.contains { $0.group == .eq }, "no EQ without calibration")
        XCTAssertTrue(plan.limitations.contains { $0.contains("calibration") })
        XCTAssertTrue(plan.settingSteps.allSatisfy(\.requiresUnlock))
    }

    func testCalibratedPlanCutsBassPeakOnly() {
        let cal = CalibrationLibrary.developerFlat(device: "t")
        let r = FrequencyResponse(frequencies: grid, db: grid.map { -20 + 8 * exp(-pow(log2($0 / 40) / 0.15, 2)) })
        let seat = SeatMeasurement(id: 0, program: ProgramResult(
            sweeps: [.left, .right, .both].map { c in
                SweepResult(channel: c, response: r, noiseFloor: FrequencyResponse(frequencies: grid, db: grid.map { _ in -90 }), arrival: 0, decay: [], impulsePreview: [], impulsePreviewRate: 1)
            },
            clockRatio: 1, latency: 0, peakInputLevel: 0.2, noiseFloorDBFS: -80))
        let data = SessionData(setup: RoomSetup(receiverID: profile.id, layout: SpeakerLayout.presets[0]), seats: [seat])
        let analysis = RoomAnalyzer(capability: .full(cal)).analyze(data)
        let plan = TuningPlanner(profile: profile).plan(for: data, analysis: analysis)
        let eq = plan.steps.compactMap { s -> (SpeakerChannel, Double, Double)? in
            if case let .eqBand(c, f, g)? = s.guide?.change { return (c, f, g) }
            return nil
        }
        XCTAssertFalse(eq.isEmpty)
        XCTAssertTrue(eq.allSatisfy { $0.2 < 0 })
        // The 40 Hz peak sits below the 80 Hz crossover, so the sub EQ handles it.
        XCTAssertTrue(eq.contains { $0.0 == .subwoofer && $0.1 == 40 })
        XCTAssertFalse(eq.contains { $0.0 != .subwoofer && $0.1 < 60 })
    }

    func testKeepRoomCorrectionSkipsEQ() {
        let cal = CalibrationLibrary.developerFlat(device: "t")
        let r = FrequencyResponse(frequencies: grid, db: grid.map { -20 + 8 * exp(-pow(log2($0 / 40) / 0.15, 2)) })
        let seat = SeatMeasurement(id: 0, program: ProgramResult(
            sweeps: [SweepResult(channel: .both, response: r, noiseFloor: FrequencyResponse(frequencies: grid, db: grid.map { _ in -90 }), arrival: 0, decay: [], impulsePreview: [], impulsePreviewRate: 1)],
            clockRatio: 1, latency: 0, peakInputLevel: 0.2, noiseFloorDBFS: -80))
        let data = SessionData(setup: RoomSetup(receiverID: profile.id, layout: SpeakerLayout.presets[0], correction: .keep), seats: [seat])
        let analysis = RoomAnalyzer(capability: .full(cal)).analyze(data)
        let plan = TuningPlanner(profile: profile).plan(for: data, analysis: analysis)
        XCTAssertFalse(plan.steps.contains { $0.group == .eq })
        XCTAssertFalse(plan.steps.contains { $0.id == "room-correction" })
        XCTAssertTrue(plan.limitations.contains { $0.contains("Dirac Live") })
    }

    func testCopyForEveryKind() {
        let kinds: [FindingKind] = [
            .levelOffset(.center, dB: -2), .bassPeak(frequency: 50, excessDB: 7, q: 4, seatsAffected: 3, seatsTotal: 3),
            .bassDip(frequency: 90, depthDB: 10, changesBetweenSeats: true), .crossoverGap(frequency: 80, depthDB: 8),
            .tonalTilt(band: 4_000...10_000, excessDB: 4), .longDecay(seconds: 0.8), .lowSignal(fractionUnreliable: 0.3),
            .subLevelNeedsCalibration,
        ]
        for k in kinds {
            let c = FindingCopy.make(for: Finding(id: "x", kind: k, severity: .noticeable, confidence: 1))
            XCTAssertFalse(c.headline.isEmpty)
            XCTAssertFalse(c.body.contains("nan"))
        }
        XCTAssertEqual(FindingCopy.make(for: Finding(id: "x", kind: .levelOffset(.center, dB: -2), severity: .gentle, confidence: 1)).headline, "Center is a little quiet")
    }
}
