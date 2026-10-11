import Foundation

public enum SpeakerChannel: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case frontLeft, frontRight, center, subwoofer
    case surroundLeft, surroundRight, surroundBackLeft, surroundBackRight
    case frontHighLeft, frontHighRight, topMiddleLeft, topMiddleRight, rearHighLeft, rearHighRight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .frontLeft: "Front left"
        case .frontRight: "Front right"
        case .center: "Center"
        case .subwoofer: "Subwoofer"
        case .surroundLeft: "Surround left"
        case .surroundRight: "Surround right"
        case .surroundBackLeft: "Surround back left"
        case .surroundBackRight: "Surround back right"
        case .frontHighLeft: "Front height left"
        case .frontHighRight: "Front height right"
        case .topMiddleLeft: "Top middle left"
        case .topMiddleRight: "Top middle right"
        case .rearHighLeft: "Rear height left"
        case .rearHighRight: "Rear height right"
        }
    }

    public var shortName: String {
        switch self {
        case .frontLeft: "FL"
        case .frontRight: "FR"
        case .center: "C"
        case .subwoofer: "SW"
        case .surroundLeft: "SL"
        case .surroundRight: "SR"
        case .surroundBackLeft: "SBL"
        case .surroundBackRight: "SBR"
        case .frontHighLeft: "FHL"
        case .frontHighRight: "FHR"
        case .topMiddleLeft: "TML"
        case .topMiddleRight: "TMR"
        case .rearHighLeft: "RHL"
        case .rearHighRight: "RHR"
        }
    }

    public var isSubwoofer: Bool { self == .subwoofer }
    public var isFrontPair: Bool { self == .frontLeft || self == .frontRight }

    /// Position on a top-down room diagram: x 0…1 left→right, y 0…1 front→back.
    public var diagramPosition: (x: Double, y: Double) {
        switch self {
        case .frontLeft: (0.2, 0.08)
        case .frontRight: (0.8, 0.08)
        case .center: (0.5, 0.05)
        case .subwoofer: (0.33, 0.06)
        case .surroundLeft: (0.04, 0.55)
        case .surroundRight: (0.96, 0.55)
        case .surroundBackLeft: (0.3, 0.95)
        case .surroundBackRight: (0.7, 0.95)
        case .frontHighLeft: (0.28, 0.22)
        case .frontHighRight: (0.72, 0.22)
        case .topMiddleLeft: (0.32, 0.5)
        case .topMiddleRight: (0.68, 0.5)
        case .rearHighLeft: (0.28, 0.78)
        case .rearHighRight: (0.72, 0.78)
        }
    }

    public static func < (a: SpeakerChannel, b: SpeakerChannel) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public struct SpeakerLayout: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var channels: [SpeakerChannel]
    public var id: String { name }

    public init(name: String, channels: [SpeakerChannel]) {
        self.name = name
        self.channels = channels.sorted()
    }

    public var hasSubwoofer: Bool { channels.contains(.subwoofer) }

    public static let presets: [SpeakerLayout] = [
        .init(name: "2.1", channels: [.frontLeft, .frontRight, .subwoofer]),
        .init(name: "3.1", channels: [.frontLeft, .frontRight, .center, .subwoofer]),
        .init(name: "5.1", channels: [.frontLeft, .frontRight, .center, .subwoofer, .surroundLeft, .surroundRight]),
        .init(name: "7.1", channels: [.frontLeft, .frontRight, .center, .subwoofer, .surroundLeft, .surroundRight, .surroundBackLeft, .surroundBackRight]),
        .init(name: "5.1.2", channels: [.frontLeft, .frontRight, .center, .subwoofer, .surroundLeft, .surroundRight, .topMiddleLeft, .topMiddleRight]),
        .init(name: "5.1.4", channels: [.frontLeft, .frontRight, .center, .subwoofer, .surroundLeft, .surroundRight, .frontHighLeft, .frontHighRight, .rearHighLeft, .rearHighRight]),
        .init(name: "7.1.2", channels: [.frontLeft, .frontRight, .center, .subwoofer, .surroundLeft, .surroundRight, .surroundBackLeft, .surroundBackRight, .topMiddleLeft, .topMiddleRight]),
        .init(name: "7.1.4", channels: [.frontLeft, .frontRight, .center, .subwoofer, .surroundLeft, .surroundRight, .surroundBackLeft, .surroundBackRight, .frontHighLeft, .frontHighRight, .rearHighLeft, .rearHighRight]),
    ]
}

/// How big the main speakers are; drives the crossover advice until we can
/// measure each speaker's own low-frequency roll-off.
public enum SpeakerSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case compact, bookshelf, tower
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .compact: "Small satellites"
        case .bookshelf: "Bookshelf"
        case .tower: "Floor-standing towers"
        }
    }
    public var suggestedCrossover: Double {
        switch self {
        case .compact: 120
        case .bookshelf: 80
        case .tower: 60
        }
    }
}

public enum RoomCorrectionChoice: String, Codable, Sendable, CaseIterable {
    /// Keep the receiver's own room correction on and fine-tune around it.
    case keep
    /// Turn it off and follow Audio Magician's plan.
    case turnOff
}
