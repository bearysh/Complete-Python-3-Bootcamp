import XCTest
import SignalKit
import Calibration
import ReceiverKit
@testable import RoomAnalysis

final class RoomAnalysisTests: XCTestCase {
    let flatCal = CalibrationLibrary.developerFlat(device: "test")

    func testLevelOffsetsFromTones() {
        let tones = [
            ToneReading(channel: .frontLeft, levelDB: -30, band: 250...4_000),
            ToneReading(channel: .frontRight, levelDB: -30, band: 250...4_000),
            ToneReading(channel: .center, levelDB: -27.5, band: 250...4_000),
            ToneReading(channel: .surroundLeft, levelDB: -30.4, band: 250...4_000),
            ToneReading(channel: .subwoofer, levelDB: -40, band: 30...120),
        ]
        let data = SessionData(setup: Fixtures.setup, tones: tones)
        let r = RoomAnalyzer(capability: .levelsOnly).analyze(data)
        let offsets = r.findings.compactMap { f -> (SpeakerChannel, Double)? in
            if case let .levelOffset(c, d) = f.kind { return (c, d) }
            return nil
        }
        XCTAssertEqual(offsets.count, 1, "only the center is ≥ 1 dB off")
        XCTAssertEqual(offsets.first?.0, .center)
        XCTAssertEqual(offsets.first?.1 ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertTrue(r.findings.contains { $0.kind == .subLevelNeedsCalibration }, "uncalibrated phones don't judge the sub")
        XCTAssertFalse(r.calibrated)
        XCTAssertTrue(r.responses.isEmpty)
    }

    func testBassPeakFoundAtAllSeats() throws {
        let r = Fixtures.response(bumps: [(50, 9, 0.12)])
        let data = SessionData(setup: Fixtures.setup, seats: [Fixtures.seat(0, r), Fixtures.seat(1, r), Fixtures.seat(2, r)])
        let result = RoomAnalyzer(capability: .full(flatCal)).analyze(data)
        let peak = try XCTUnwrap(result.findings.compactMap { f -> (Double, Double, Int)? in
            if case let .bassPeak(fq, ex, _, a, _) = f.kind { return (fq, ex, a) }
            return nil
        }.first)
        XCTAssertEqual(peak.0, 50, accuracy: 3)
        XCTAssertEqual(peak.1, 9, accuracy: 1.5)
        XCTAssertEqual(peak.2, 3)
        XCTAssertLessThan(result.score, 100)
    }

    func testDipThatMovesBetweenSeats() throws {
        let seats = [
            Fixtures.seat(0, Fixtures.response(bumps: [(70, -18, 0.2)])),
            Fixtures.seat(1, Fixtures.response(bumps: [(70, -4, 0.2)])),
            Fixtures.seat(2, Fixtures.response(bumps: [(70, -16, 0.2)])),
        ]
        let result = RoomAnalyzer(capability: .full(flatCal)).analyze(SessionData(setup: Fixtures.setup, seats: seats))
        let dip = try XCTUnwrap(result.findings.compactMap { f -> Bool? in
            if case let .bassDip(_, _, varies) = f.kind { return varies }
            return nil
        }.first)
        XCTAssertTrue(dip)
    }

    func testFlatRoomScoresHigh() {
        let r = Fixtures.response()
        let result = RoomAnalyzer(capability: .full(flatCal)).analyze(SessionData(setup: Fixtures.setup, seats: [Fixtures.seat(0, r)]))
        XCTAssertTrue(result.findings.isEmpty, "\(result.findings)")
        XCTAssertEqual(result.score, 100)
    }

    func testNoisyRegionIsIgnored() {
        // A big peak at 40 Hz, but the noise floor there is above the signal.
        let r = Fixtures.response(bumps: [(40, 10, 0.1)])
        var seat = Fixtures.seat(0, r)
        for i in seat.program.sweeps.indices {
            seat.program.sweeps[i].noiseFloor = FrequencyResponse(frequencies: Fixtures.grid, db: Fixtures.grid.map { $0 < 60 ? 0 : -90 })
        }
        let result = RoomAnalyzer(capability: .full(flatCal)).analyze(SessionData(setup: Fixtures.setup, seats: [seat]))
        XCTAssertFalse(result.findings.contains { if case .bassPeak = $0.kind { return true } else { return false } })
    }
}
