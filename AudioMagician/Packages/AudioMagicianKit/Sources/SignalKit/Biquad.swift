import Foundation

/// Peaking EQ filter (RBJ Audio EQ Cookbook) — the shape most receiver EQs use.
public struct PeakingFilter: Codable, Sendable, Equatable {
    public var frequency: Double
    public var gainDB: Double
    public var q: Double

    public init(frequency: Double, gainDB: Double, q: Double) {
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }

    /// Magnitude response in dB at `f`, evaluated at `sampleRate`.
    public func responseDB(at f: Double, sampleRate: Double = 48_000) -> Double {
        guard gainDB != 0 else { return 0 }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let b0 = 1 + alpha * a, b1 = -2 * cw, b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cw, a2 = 1 - alpha / a
        let w = 2 * Double.pi * f / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag2 = (nr * nr + ni * ni) / (dr * dr + di * di)
        return 10 * log10(mag2)
    }

    public static func combinedDB(_ filters: [PeakingFilter], at f: Double, sampleRate: Double = 48_000) -> Double {
        filters.reduce(0) { $0 + $1.responseDB(at: f, sampleRate: sampleRate) }
    }
}
