import Foundation

/// Magnitude response sampled on a log-spaced frequency grid.
public struct FrequencyResponse: Codable, Sendable, Equatable {
    public var frequencies: [Double]
    public var db: [Double]

    public init(frequencies: [Double], db: [Double]) {
        precondition(frequencies.count == db.count)
        self.frequencies = frequencies
        self.db = db
    }

    public var isEmpty: Bool { frequencies.isEmpty }

    /// Linear-in-log-frequency interpolation; clamps at the ends.
    public func value(at f: Double) -> Double {
        guard let first = frequencies.first, let last = frequencies.last else { return 0 }
        if f <= first { return db[0] }
        if f >= last { return db[db.count - 1] }
        var lo = 0, hi = frequencies.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= f { lo = mid } else { hi = mid }
        }
        let t = log(f / frequencies[lo]) / log(frequencies[hi] / frequencies[lo])
        return db[lo] + t * (db[hi] - db[lo])
    }

    /// Mean level (power average) over a band.
    public func meanLevel(in band: ClosedRange<Double>) -> Double {
        var sum = 0.0, n = 0
        for (f, d) in zip(frequencies, db) where band.contains(f) {
            sum += pow(10, d / 10)
            n += 1
        }
        guard n > 0 else { return value(at: sqrt(band.lowerBound * band.upperBound)) }
        return 10 * log10(sum / Double(n))
    }

    public func offset(by d: Double) -> FrequencyResponse {
        FrequencyResponse(frequencies: frequencies, db: db.map { $0 + d })
    }

    /// Pointwise a - b (grids must match).
    public static func - (a: FrequencyResponse, b: FrequencyResponse) -> FrequencyResponse {
        FrequencyResponse(frequencies: a.frequencies, db: zip(a.db, b.db).map { $0 - $1 })
    }

    /// Fractional-octave smoothing of an already gridded response (power domain).
    public func smoothed(fraction: Double) -> FrequencyResponse {
        guard frequencies.count > 2 else { return self }
        let half = 1.0 / (2 * fraction)
        let logs = frequencies.map(log2)
        let power = db.map { pow(10, $0 / 10) }
        var out = [Double](repeating: 0, count: db.count)
        var lo = 0, hi = 0
        var acc = 0.0
        for i in 0..<frequencies.count {
            while hi < frequencies.count && logs[hi] <= logs[i] + half { acc += power[hi]; hi += 1 }
            while lo < hi && logs[lo] < logs[i] - half { acc -= power[lo]; lo += 1 }
            out[i] = 10 * log10(max(acc / Double(hi - lo), 1e-30))
        }
        return FrequencyResponse(frequencies: frequencies, db: out)
    }
}

public enum LogGrid {
    /// Log-spaced frequencies from `low` to `high` inclusive.
    public static func make(from low: Double = 10, to high: Double = 20_000, pointsPerOctave: Int = 48) -> [Double] {
        let octaves = log2(high / low)
        let count = Int((octaves * Double(pointsPerOctave)).rounded()) + 1
        return (0..<count).map { low * pow(2, Double($0) / Double(pointsPerOctave)) }
    }

    public static let standard: [Double] = make()
}

public enum Smoothing {
    /// Converts a per-bin power spectrum (bins 0...N/2) to fractional-octave
    /// smoothed dB values on `grid`. Bands narrower than one bin fall back to
    /// interpolating the nearest bins.
    public static func fractionalOctave(power: [Double], binHz: Double, grid: [Double], fraction: Double) -> [Double] {
        var prefix = [Double](repeating: 0, count: power.count + 1)
        for i in 0..<power.count { prefix[i + 1] = prefix[i] + power[i] }
        let factor = pow(2, 1 / (2 * fraction))
        return grid.map { fc in
            let lo = fc / factor, hi = fc * factor
            let a = max(1, Int(ceil(lo / binHz)))
            let b = min(power.count - 1, Int(floor(hi / binHz)))
            let p: Double
            if b >= a {
                p = (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
            } else {
                let x = fc / binHz
                let i0 = max(0, min(power.count - 2, Int(floor(x))))
                let t = x - Double(i0)
                p = power[i0] * (1 - t) + power[i0 + 1] * t
            }
            return 10 * log10(max(p, 1e-30))
        }
    }

    /// Power average of several responses on the same grid, plus the spread
    /// (standard deviation of dB values) at each point.
    public static func average(_ responses: [FrequencyResponse]) -> (mean: FrequencyResponse, spreadDB: [Double])? {
        guard let first = responses.first else { return nil }
        let n = Double(responses.count)
        var mean = [Double](repeating: 0, count: first.db.count)
        var spread = [Double](repeating: 0, count: first.db.count)
        for i in 0..<first.db.count {
            let vals = responses.map { $0.db[i] }
            let p = vals.reduce(0) { $0 + pow(10, $1 / 10) } / n
            mean[i] = 10 * log10(p)
            let m = vals.reduce(0, +) / n
            spread[i] = sqrt(vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n)
        }
        return (FrequencyResponse(frequencies: first.frequencies, db: mean), spread)
    }
}
