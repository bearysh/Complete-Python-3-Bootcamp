import Foundation

/// A single receiver setting the plan wants changed. Receiver-agnostic; a
/// controller turns it into user steps (v1) or network commands (later).
public enum SettingChange: Codable, Sendable, Equatable, Hashable {
    case level(SpeakerChannel, dB: Double)
    case distance(SpeakerChannel, meters: Double)
    case crossover(Double)
    case eqBand(SpeakerChannel, frequency: Double, gainDB: Double)
    case roomCorrection(enabled: Bool)
    case subwooferPhase(inverted: Bool)
}

/// A step the user performs on the receiver.
public struct GuideStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var menu: MenuPath?
    public var valueText: String
    public var change: SettingChange

    public init(id: String, title: String, menu: MenuPath?, valueText: String, change: SettingChange) {
        self.id = id
        self.title = title
        self.menu = menu
        self.valueText = valueText
        self.change = change
    }
}

public enum ApplyResult: Sendable, Equatable {
    /// The controller changed the settings itself.
    case applied
    /// The user has to make these changes by hand.
    case needsUser([GuideStep])
}

public protocol ReceiverController: Sendable {
    var profile: ReceiverProfile { get }
    func apply(_ changes: [SettingChange]) async throws -> ApplyResult
}

/// v1 controller: turns changes into ordered, plain-language steps.
/// A Wi-Fi controller (Onkyo eISCP, Yamaha YXC, Denon HTTP/Telnet) will conform
/// to the same protocol.
public struct ManualGuideController: ReceiverController {
    public let profile: ReceiverProfile

    public init(profile: ReceiverProfile) {
        self.profile = profile
    }

    public func apply(_ changes: [SettingChange]) async throws -> ApplyResult {
        .needsUser(steps(for: changes))
    }

    public func steps(for changes: [SettingChange]) -> [GuideStep] {
        changes.sorted(by: Self.order).map { step(for: $0) }
    }

    public func step(for change: SettingChange) -> GuideStep {
        switch change {
        case let .level(ch, dB):
            return GuideStep(id: "level-\(ch.rawValue)", title: "\(ch.displayName) level", menu: profile.menu(.levels), valueText: Format.signedDB(dB), change: change)
        case let .distance(ch, m):
            return GuideStep(id: "distance-\(ch.rawValue)", title: "\(ch.displayName) distance", menu: profile.menu(.distances), valueText: Format.meters(m), change: change)
        case let .crossover(hz):
            return GuideStep(id: "crossover", title: "Speaker crossover", menu: profile.menu(.crossover), valueText: "\(Int(hz)) Hz", change: change)
        case let .eqBand(ch, f, g):
            return GuideStep(id: "eq-\(ch.rawValue)-\(Int(f))", title: "\(ch.displayName) EQ · \(Format.frequency(f))", menu: profile.menu(.manualEQ), valueText: Format.signedDB(g), change: change)
        case let .roomCorrection(on):
            let name = profile.roomCorrectionSystems.first ?? "Room correction"
            return GuideStep(id: "room-correction", title: name, menu: profile.menu(.roomCorrectionToggle), valueText: on ? "On" : "Off", change: change)
        case let .subwooferPhase(inverted):
            return GuideStep(id: "sub-phase", title: "Subwoofer phase", menu: profile.menu(.subwooferPhase), valueText: inverted ? "180°" : "0°", change: change)
        }
    }

    /// Menu order: room correction, then levels, distances, crossover, phase, EQ.
    static func order(_ a: SettingChange, _ b: SettingChange) -> Bool {
        func rank(_ c: SettingChange) -> (Int, Int, Double) {
            switch c {
            case .roomCorrection: (0, 0, 0)
            case let .level(ch, _): (1, SpeakerChannel.allCases.firstIndex(of: ch)!, 0)
            case let .distance(ch, _): (2, SpeakerChannel.allCases.firstIndex(of: ch)!, 0)
            case .crossover: (3, 0, 0)
            case .subwooferPhase: (4, 0, 0)
            case let .eqBand(ch, f, _): (5, SpeakerChannel.allCases.firstIndex(of: ch)!, f)
            }
        }
        return rank(a) < rank(b)
    }
}

public enum Format {
    public static func signedDB(_ v: Double) -> String {
        let s = v == v.rounded() ? String(format: "%.0f", abs(v)) : String(format: "%.1f", abs(v))
        if v > 0 { return "+\(s) dB" }
        if v < 0 { return "−\(s) dB" }
        return "0 dB"
    }

    public static func meters(_ m: Double) -> String {
        let feet = m / 0.3048
        return String(format: "%.2f m (%.1f ft)", m, feet)
    }

    public static func frequency(_ f: Double) -> String {
        f >= 1000 ? String(format: f.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", f / 1000) : "\(Int(f.rounded())) Hz"
    }
}
