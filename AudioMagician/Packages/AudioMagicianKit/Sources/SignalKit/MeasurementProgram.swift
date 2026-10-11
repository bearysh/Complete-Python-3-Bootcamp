import Foundation

/// Which speakers a sweep is sent to over the stereo Bluetooth link.
public enum SweepChannel: String, Codable, Sendable, CaseIterable {
    case left, right, both
}

/// The full stimulus played in one go:
///
///     [silence: noise floor] [marker A] [gap] [sweep L] [tail] [sweep R] [tail] [sweep L+R] [tail] [marker B] [silence]
///
/// Everything is timed relative to marker A, so Bluetooth latency cancels out,
/// and marker B gives the clock-drift ratio.
public struct MeasurementProgram: Codable, Sendable, Equatable {
    public var sweep: SweepParameters
    public var channels: [SweepChannel]
    public var preSilence: Double
    public var markerDuration: Double
    public var gapAfterMarker: Double
    /// Silence after each sweep so the room can decay before the next one.
    public var tail: Double
    public var postSilence: Double

    public init(
        sweep: SweepParameters = SweepParameters(),
        channels: [SweepChannel] = [.left, .right, .both],
        preSilence: Double = 2.0,
        markerDuration: Double = 0.25,
        gapAfterMarker: Double = 0.75,
        tail: Double = 1.5,
        postSilence: Double = 0.5
    ) {
        self.sweep = sweep
        self.channels = channels
        self.preSilence = preSilence
        self.markerDuration = markerDuration
        self.gapAfterMarker = gapAfterMarker
        self.tail = tail
        self.postSilence = postSilence
    }

    public var sampleRate: Double { sweep.sampleRate }

    func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    public var markerAStart: Int { samples(preSilence) }
    public var markerLength: Int { samples(markerDuration) }

    public func sweepStart(index: Int) -> Int {
        markerAStart + markerLength + samples(gapAfterMarker) + index * (sweep.sampleCount + samples(tail))
    }

    public var markerBStart: Int { sweepStart(index: channels.count) }
    public var totalLength: Int { markerBStart + markerLength + samples(postSilence) }
    public var duration: Double { Double(totalLength) / sampleRate }

    /// Noise-floor window: the silence before marker A, minus a safety margin.
    public var noiseRange: Range<Int> {
        let start = samples(0.2)
        return start..<max(start + 1, markerAStart - samples(0.2))
    }

    public var marker: [Double] { Alignment.marker(sampleRate: sampleRate, duration: markerDuration) }

    /// Renders the stereo stimulus as Float buffers for AVAudioEngine.
    public func render() -> (left: [Float], right: [Float]) {
        var l = [Float](repeating: 0, count: totalLength)
        var r = [Float](repeating: 0, count: totalLength)
        func write(_ x: [Double], at start: Int, left: Bool, right: Bool) {
            for (i, v) in x.enumerated() {
                if left { l[start + i] = Float(v) }
                if right { r[start + i] = Float(v) }
            }
        }
        let m = marker
        write(m, at: markerAStart, left: true, right: true)
        let s = ExponentialSweep.generate(sweep)
        for (i, ch) in channels.enumerated() {
            write(s, at: sweepStart(index: i), left: ch != .right, right: ch != .left)
        }
        write(m, at: markerBStart, left: true, right: true)
        return (l, r)
    }
}
