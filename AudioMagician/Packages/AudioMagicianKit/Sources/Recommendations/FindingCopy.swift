import Foundation
import ReceiverKit
import RoomAnalysis

/// Warm, jargon-free words for each finding. Kept beside the engine so copy and
/// logic are tested together.
public struct FindingCopy: Sendable, Equatable {
    public var headline: String
    public var body: String
    /// Short tag for the card ("Bass", "Balance"…).
    public var tag: String
    /// A short hint of the fix, shown on the results card even before unlocking.
    public var fixHint: String

    public static func make(for finding: Finding) -> FindingCopy {
        switch finding.kind {
        case let .levelOffset(ch, dB):
            let louder = dB > 0
            return FindingCopy(
                headline: "\(ch.displayName) is a little \(louder ? "loud" : "quiet")",
                body: "It plays about \(String(format: "%.1f", abs(dB))) dB \(louder ? "louder" : "softer") than your front speakers, so sound can feel pulled \(louder ? "toward" : "away from") it.",
                tag: "Balance",
                fixHint: "A quick level change on your receiver")
        case let .bassPeak(f, ex, _, affected, total):
            let seats = total > 1 ? " at \(affected) of your \(total) seats" : ""
            return FindingCopy(
                headline: "Bass booms around \(Format.frequency(f))",
                body: "Your room is boosting one bass note by about \(Int(ex.rounded())) dB\(seats). It can make some notes thump while others disappear.",
                tag: "Bass",
                fixHint: "A gentle EQ cut")
        case let .bassDip(f, d, varies):
            return FindingCopy(
                headline: "A bass hole near \(Format.frequency(f))",
                body: varies
                    ? "Bass drops by about \(Int(d.rounded())) dB here, and it shifts from seat to seat. That's the room's shape at work."
                    : "Bass drops by about \(Int(d.rounded())) dB here at every seat, usually from sound bouncing off a nearby wall.",
                tag: "Bass",
                fixHint: "Moving a speaker, not EQ")
        case let .crossoverGap(f, d):
            return FindingCopy(
                headline: "Your sub and speakers aren't quite blending",
                body: "Around \(Format.frequency(f)) they partly cancel, leaving a \(Int(d.rounded())) dB gap where they hand off.",
                tag: "Subwoofer",
                fixHint: "A crossover and phase check")
        case let .tonalTilt(band, ex):
            let area = band.upperBound <= 1_000 ? "lower mids" : (band.upperBound <= 4_000 ? "voices and mids" : "treble")
            return FindingCopy(
                headline: "The \(area) stand out a bit",
                body: "That range is about \(Int(ex.rounded())) dB stronger than the rest, which can sound \(band.upperBound > 4_000 ? "bright or sharp" : "forward or boxy").",
                tag: "Tone",
                fixHint: "A broad, gentle EQ cut")
        case let .longDecay(t):
            return FindingCopy(
                headline: "Your room is a little echoey",
                body: "Sound hangs around for about \(String(format: "%.1f", t)) seconds. Soft furnishings would make dialogue crisper.",
                tag: "Room",
                fixHint: "A rug, curtains or bookshelf")
        case let .lowSignal(frac):
            return FindingCopy(
                headline: "Some of the sound was hard to hear",
                body: "About \(Int((frac * 100).rounded()))% of the range was too close to background noise to judge, so we left it alone.",
                tag: "Measurement",
                fixHint: "Measure a little louder")
        case .subLevelNeedsCalibration:
            return FindingCopy(
                headline: "Subwoofer level: coming soon",
                body: "Judging deep bass needs your iPhone's microphone calibration. Everything else in this check is accurate.",
                tag: "Subwoofer",
                fixHint: "Arrives in an update")
        }
    }
}

public enum ScoreCopy {
    public static func headline(score: Int) -> String {
        switch score {
        case 90...: "Your room already sounds lovely"
        case 75..<90: "Your room sounds good, with a few easy wins"
        case 55..<75: "A few changes will make a real difference"
        default: "Your room has a lot to gain"
        }
    }
}
