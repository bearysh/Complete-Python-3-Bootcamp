import Foundation

/// A numeric receiver control (level trim, distance…).
public struct ControlRange: Codable, Sendable, Equatable {
    public var min: Double
    public var max: Double
    public var step: Double
    public var unit: String

    public init(min: Double, max: Double, step: Double, unit: String) {
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
    }

    /// Nearest value the receiver can actually be set to.
    public func quantize(_ v: Double) -> Double {
        let clamped = Swift.min(max, Swift.max(min, v))
        let q = (clamped / step).rounded() * step
        // Tidy floating-point noise (e.g. 0.30000000000000004).
        return (q * 1000).rounded() / 1000
    }
}

public struct MenuPath: Codable, Sendable, Equatable {
    /// Each tap, in order, e.g. ["Setup", "Speaker", "Level Calibration"].
    public var steps: [String]
    /// Extra guidance shown under the path.
    public var note: String?

    public init(steps: [String], note: String? = nil) {
        self.steps = steps
        self.note = note
    }

    public var display: String { steps.joined(separator: " › ") }
}

public struct EQCapability: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Fixed centre frequencies, adjustable gain.
        case graphic
        /// Adjustable frequency, gain and Q.
        case parametric
        case none
    }

    public var kind: Kind
    /// Band centres for speaker channels (graphic EQ).
    public var bands: [Double]
    /// Band centres for the subwoofer channel; empty if the sub has no EQ.
    public var subwooferBands: [Double]
    public var gain: ControlRange
    /// Filter Q assumed for each graphic band when predicting its effect.
    public var bandQ: Double
    /// Whether manual EQ can be used while the built-in room correction is on.
    public var availableWithRoomCorrection: Bool
    /// Maximum number of filters per channel (parametric only).
    public var maxFiltersPerChannel: Int?
}

public struct ReceiverProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var brand: String
    public var model: String
    /// False until every value has been checked against real hardware.
    public var verified: Bool
    public var roomCorrectionSystems: [String]
    public var channelLevel: ControlRange
    public var subwooferLevel: ControlRange
    public var distance: ControlRange
    /// Crossover frequencies the receiver offers, Hz.
    public var crossoverOptions: [Double]
    public var eq: EQCapability
    /// Order in which the receiver's test tone visits channels.
    public var testToneOrder: [SpeakerChannel]
    /// Named menu paths, keyed by `MenuKey` raw values.
    public var menus: [String: MenuPath]
    public var notes: [String]

    public static func == (a: ReceiverProfile, b: ReceiverProfile) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var displayName: String { "\(brand) \(model)" }

    public func menu(_ key: MenuKey) -> MenuPath? { menus[key.rawValue] }

    public func nearestCrossover(to hz: Double) -> Double {
        crossoverOptions.min { abs(log($0 / hz)) < abs(log($1 / hz)) } ?? hz
    }

    public func levelRange(for channel: SpeakerChannel) -> ControlRange {
        channel.isSubwoofer ? subwooferLevel : channelLevel
    }

    public func eqBands(for channel: SpeakerChannel) -> [Double] {
        channel.isSubwoofer ? eq.subwooferBands : eq.bands
    }
}

public enum MenuKey: String, Codable, Sendable, CaseIterable {
    case bluetoothInput
    case stereoMode
    case dynamicFeaturesOff
    case roomCorrectionToggle
    case levels
    case testTone
    case distances
    case crossover
    case manualEQ
    case subwooferPhase
}

public enum ProfileLibrary {
    /// Every receiver profile bundled with the app.
    public static func bundled() -> [ReceiverProfile] {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ReceiverProfile.self, from: data)
        }
        .sorted { $0.displayName < $1.displayName }
    }

    public static func profile(id: String) -> ReceiverProfile? {
        bundled().first { $0.id == id }
    }
}
