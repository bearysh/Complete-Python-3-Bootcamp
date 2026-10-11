import XCTest
@testable import ReceiverKit
@testable import Calibration
import SignalKit

final class ReceiverKitTests: XCTestCase {
    func testBundledRZ50Profile() throws {
        let p = try XCTUnwrap(ProfileLibrary.profile(id: "onkyo-tx-rz50"))
        XCTAssertEqual(p.displayName, "Onkyo TX-RZ50")
        XCTAssertEqual(p.eq.kind, .graphic)
        XCTAssertFalse(p.verified, "Flip to true only once checked on hardware")
        for key in MenuKey.allCases {
            XCTAssertNotNil(p.menu(key), "missing menu path for \(key)")
        }
        XCTAssertEqual(Set(p.testToneOrder), Set(SpeakerChannel.allCases))
    }

    func testQuantize() {
        let r = ControlRange(min: -12, max: 12, step: 0.5, unit: "dB")
        XCTAssertEqual(r.quantize(1.26), 1.5)
        XCTAssertEqual(r.quantize(-20), -12)
        let d = ControlRange(min: 0.3, max: 9, step: 0.03, unit: "m")
        XCTAssertEqual(d.quantize(3.10), 3.09, accuracy: 1e-9)
    }

    func testNearestCrossover() throws {
        let p = try XCTUnwrap(ProfileLibrary.profile(id: "onkyo-tx-rz50"))
        XCTAssertEqual(p.nearestCrossover(to: 85), 90)
        XCTAssertEqual(p.nearestCrossover(to: 110), 100)
    }

    func testGuideOrdering() async throws {
        let p = try XCTUnwrap(ProfileLibrary.profile(id: "onkyo-tx-rz50"))
        let c = ManualGuideController(profile: p)
        let result = try await c.apply([.eqBand(.frontLeft, frequency: 63, gainDB: -3), .level(.center, dB: -1), .roomCorrection(enabled: false)])
        guard case let .needsUser(steps) = result else { return XCTFail() }
        XCTAssertEqual(steps.map(\.id), ["room-correction", "level-center", "eq-frontLeft-63"])
    }

    func testFormat() {
        XCTAssertEqual(Format.signedDB(-1.5), "−1.5 dB")
        XCTAssertEqual(Format.signedDB(2), "+2 dB")
        XCTAssertEqual(Format.frequency(2_500), "2.5 kHz")
        XCTAssertEqual(Format.frequency(63), "63 Hz")
    }

    func testCalibrationLibrary() {
        let lib = CalibrationLibrary.bundled()
        XCTAssertEqual(lib.capability(forDevice: "iPhone18,2"), .levelsOnly)
        let cal = MicCalibration(id: "t", displayName: "t", deviceIdentifiers: ["x"], points: [.init(frequency: 20, deviationDB: -10), .init(frequency: 200, deviationDB: 0)])
        let raw = FrequencyResponse(frequencies: [20, 200], db: [-10, 0])
        XCTAssertEqual(cal.apply(to: raw).db, [0, 0])
        XCTAssertTrue(CalibrationLibrary(calibrations: [cal]).capability(forDevice: "x").isCalibrated)
    }
}
