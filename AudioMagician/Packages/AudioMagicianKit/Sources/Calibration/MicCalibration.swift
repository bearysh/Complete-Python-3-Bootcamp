import Foundation
import SignalKit

/// A phone microphone's deviation from flat, measured against a reference mic.
///
/// Subtracting `correction(at:)` from a raw measurement gives the true response.
/// Curves are tied to one microphone, one orientation and `.measurement` mode;
/// anything else invalidates them.
public struct MicCalibration: Codable, Sendable, Equatable, Identifiable {
    public struct Point: Codable, Sendable, Equatable {
        public var frequency: Double
        /// Phone minus reference, dB.
        public var deviationDB: Double
        /// One standard deviation across calibrated units, dB.
        public var uncertaintyDB: Double?

        public init(frequency: Double, deviationDB: Double, uncertaintyDB: Double? = nil) {
            self.frequency = frequency
            self.deviationDB = deviationDB
            self.uncertaintyDB = uncertaintyDB
        }
    }

    public var id: String
    public var displayName: String
    /// `utsname.machine` values this curve applies to, e.g. "iPhone18,2".
    public var deviceIdentifiers: [String]
    /// "bottom", "front" or "back" (AVAudioSession data-source orientation).
    public var micDataSource: String
    /// Angle between the mic axis and the speakers: 90 = phone pointing at the ceiling.
    public var orientationDegrees: Int
    /// Digital full scale expressed as SPL, if the absolute sensitivity was measured.
    public var fullScaleSPL: Double?
    public var points: [Point]
    public var version: Int
    public var notes: String?

    public init(id: String, displayName: String, deviceIdentifiers: [String], micDataSource: String = "bottom", orientationDegrees: Int = 90, fullScaleSPL: Double? = nil, points: [Point], version: Int = 1, notes: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.deviceIdentifiers = deviceIdentifiers
        self.micDataSource = micDataSource
        self.orientationDegrees = orientationDegrees
        self.fullScaleSPL = fullScaleSPL
        self.points = points.sorted { $0.frequency < $1.frequency }
        self.version = version
        self.notes = notes
    }

    private var curve: FrequencyResponse {
        FrequencyResponse(frequencies: points.map(\.frequency), db: points.map(\.deviationDB))
    }

    public func correction(at f: Double) -> Double { curve.value(at: f) }

    public func uncertainty(at f: Double) -> Double {
        let u = points.map { $0.uncertaintyDB ?? 0 }
        return FrequencyResponse(frequencies: points.map(\.frequency), db: u).value(at: f)
    }

    /// Removes the microphone's own colouration from a raw response.
    public func apply(to raw: FrequencyResponse) -> FrequencyResponse {
        FrequencyResponse(frequencies: raw.frequencies, db: zip(raw.frequencies, raw.db).map { $1 - correction(at: $0) })
    }
}

/// What the current phone can do.
public enum MeasurementCapability: Sendable, Equatable {
    /// A calibration curve exists: full sweeps, EQ and crossover advice.
    case full(MicCalibration)
    /// No curve: channel levels (relative, so the mic's colouration cancels) and distances only.
    case levelsOnly

    public var isCalibrated: Bool {
        if case .full = self { return true }
        return false
    }

    public var calibration: MicCalibration? {
        if case .full(let c) = self { return c }
        return nil
    }
}

public struct CalibrationLibrary: Codable, Sendable {
    public var version: Int
    public var calibrations: [MicCalibration]

    public init(version: Int = 1, calibrations: [MicCalibration] = []) {
        self.version = version
        self.calibrations = calibrations
    }

    /// The curves shipped inside the app.
    public static func bundled() -> CalibrationLibrary {
        guard let url = Bundle.module.url(forResource: "calibrations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(CalibrationLibrary.self, from: data) else {
            return CalibrationLibrary()
        }
        return lib
    }

    public func calibration(forDevice identifier: String) -> MicCalibration? {
        calibrations.first { $0.deviceIdentifiers.contains(identifier) }
    }

    public func capability(forDevice identifier: String) -> MeasurementCapability {
        calibration(forDevice: identifier).map(MeasurementCapability.full) ?? .levelsOnly
    }

    /// Flat placeholder used only by developer builds to exercise the full flow
    /// before real curves exist. Never shipped as a real calibration.
    public static func developerFlat(device: String) -> MicCalibration {
        MicCalibration(
            id: "developer-flat",
            displayName: "Developer flat curve (NOT a real calibration)",
            deviceIdentifiers: [device],
            points: [.init(frequency: 10, deviationDB: 0, uncertaintyDB: 6), .init(frequency: 20_000, deviationDB: 0, uncertaintyDB: 6)],
            notes: "Placeholder. Results below 100 Hz and above 10 kHz are not trustworthy."
        )
    }
}
