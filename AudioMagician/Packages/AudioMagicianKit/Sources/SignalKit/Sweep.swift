import Foundation

/// Exponential (log) sine sweep, after Farina (AES 108 / AES 122).
public struct SweepParameters: Codable, Sendable, Equatable {
    public var startFrequency: Double
    public var endFrequency: Double
    public var duration: Double
    public var sampleRate: Double
    /// Raised-cosine fade at the start, seconds. Keeps the 10 Hz onset click-free.
    public var fadeIn: Double
    /// Raised-cosine fade at the end, seconds.
    public var fadeOut: Double
    /// Peak amplitude, linear full scale.
    public var amplitude: Double

    public init(
        startFrequency: Double = 10,
        endFrequency: Double = 20_000,
        duration: Double = 8,
        sampleRate: Double = 48_000,
        fadeIn: Double = 0.1,
        fadeOut: Double = 0.02,
        amplitude: Double = 0.5
    ) {
        self.startFrequency = startFrequency
        self.endFrequency = min(endFrequency, sampleRate * 0.45)
        self.duration = duration
        self.sampleRate = sampleRate
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.amplitude = amplitude
    }

    public var sampleCount: Int { Int((duration * sampleRate).rounded()) }

    /// Time by which the k-th harmonic's response precedes the linear response.
    public func harmonicLead(order k: Int) -> Double {
        duration * log(Double(k)) / log(endFrequency / startFrequency)
    }
}

public enum ExponentialSweep {
    public static func generate(_ p: SweepParameters) -> [Double] {
        let n = p.sampleCount
        let rate = log(p.endFrequency / p.startFrequency)
        let l = p.duration / rate
        let k = 2 * Double.pi * p.startFrequency * l
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / p.sampleRate
            out[i] = p.amplitude * sin(k * (exp(t / l) - 1))
        }
        Window.applyFades(&out, fadeIn: Int(p.fadeIn * p.sampleRate), fadeOut: Int(p.fadeOut * p.sampleRate))
        return out
    }
}

public enum Window {
    /// Raised-cosine fades applied in place.
    public static func applyFades(_ x: inout [Double], fadeIn: Int, fadeOut: Int) {
        let n = x.count
        let fi = min(fadeIn, n)
        let fo = min(fadeOut, n)
        if fi > 0 {
            for i in 0..<fi { x[i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fi)) }
        }
        if fo > 0 {
            for i in 0..<fo { x[n - 1 - i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fo)) }
        }
    }

    public static func hann(_ n: Int) -> [Double] {
        guard n > 1 else { return [1] }
        return (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    }
}
