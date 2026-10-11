import Foundation
import SignalKit
import ReceiverKit

public enum Severity: Int, Codable, Sendable, Comparable {
    case gentle = 0, noticeable = 1, significant = 2

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    static func from(magnitude dB: Double, noticeable: Double, significant: Double) -> Severity {
        dB >= significant ? .significant : (dB >= noticeable ? .noticeable : .gentle)
    }
}

public enum FindingKind: Codable, Sendable, Equatable {
    /// A speaker plays louder (+) or quieter (−) than the front pair.
    case levelOffset(SpeakerChannel, dB: Double)
    /// A bass build-up (room mode) at the listening area.
    case bassPeak(frequency: Double, excessDB: Double, q: Double, seatsAffected: Int, seatsTotal: Int)
    /// A dip. EQ can't fix these; placement can.
    case bassDip(frequency: Double, depthDB: Double, changesBetweenSeats: Bool)
    /// The sub and main speakers partly cancel around the crossover.
    case crossoverGap(frequency: Double, depthDB: Double)
    /// Treble/mid balance off by a broad amount (above the room-mode region).
    case tonalTilt(band: ClosedRange<Double>, excessDB: Double)
    /// The room rings on too long (echoey).
    case longDecay(seconds: Double)
    /// Parts of the range were too close to the background noise to judge.
    case lowSignal(fractionUnreliable: Double)
    /// Sub level not judged because this phone isn't calibrated for deep bass.
    case subLevelNeedsCalibration
}

public struct Finding: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: FindingKind
    public var severity: Severity
    /// 0…1: how sure we are, from SNR, seat agreement and calibration uncertainty.
    public var confidence: Double

    public init(id: String, kind: FindingKind, severity: Severity, confidence: Double) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.confidence = confidence
    }
}

/// Response curves prepared for display and for the EQ fitter.
public struct ResponseSummary: Codable, Sendable, Equatable {
    public var channel: SweepChannel
    /// Calibrated, power-averaged across seats.
    public var average: FrequencyResponse
    /// Standard deviation across seats at each grid point, dB.
    public var spreadDB: [Double]
    public var perSeat: [FrequencyResponse]
    /// Worst (highest) noise floor across seats, calibrated the same way.
    public var noiseFloor: FrequencyResponse
    /// True where every seat had at least the required SNR.
    public var reliable: [Bool]
}

public struct AnalysisResult: Codable, Sendable, Equatable {
    public var findings: [Finding]
    public var responses: [ResponseSummary]
    /// Level the curves are judged against (mean 200 Hz–2 kHz of the L+R average), dB.
    public var referenceLevel: Double?
    public var decay: [DecayBand]
    public var tones: [ToneReading]
    /// 0…100, higher is better. A friendly single number for the results headline.
    public var score: Int
    public var calibrated: Bool

    public func response(_ c: SweepChannel) -> ResponseSummary? { responses.first { $0.channel == c } }
}
