import Foundation
import SignalKit
import ReceiverKit

/// Fits EQ to a desired correction curve within what the receiver offers.
///
/// Policy (hard rules): cuts only, never boosts. The desired curve passed in is
/// already ≤ 0 everywhere and zero wherever we don't trust the measurement.
public enum EQFitter {
    /// Bounded least squares over fixed graphic-EQ bands.
    ///
    /// Minimises Σ w(f)·(Σ_k B_k(f; g_k) − d(f))² with g_k ∈ [gain.min, 0], then
    /// rounds each gain to the receiver's step. Uses coordinate descent on the
    /// exact biquad responses, so overlapping bands are handled correctly.
    public static func fitGraphic(desired: FrequencyResponse, weights: [Double], bands: [Double], gain: ControlRange, q: Double, iterations: Int = 60) -> [Double] {
        let f = desired.frequencies
        let lowest = min(0, gain.max) // never boost
        let floorGain = gain.min
        var g = [Double](repeating: 0, count: bands.count)
        func total(_ i: Int, excluding k: Int) -> Double {
            var s = 0.0
            for j in bands.indices where j != k && g[j] != 0 {
                s += PeakingFilter(frequency: bands[j], gainDB: g[j], q: q).responseDB(at: f[i])
            }
            return s
        }
        for _ in 0..<iterations {
            var changed = false
            for k in bands.indices {
                let others = f.indices.map { total($0, excluding: k) }
                // Golden-section search for band k's gain on [floorGain, lowest].
                func cost(_ x: Double) -> Double {
                    var c = 0.0
                    let filter = PeakingFilter(frequency: bands[k], gainDB: x, q: q)
                    for i in f.indices where weights[i] > 0 {
                        let e = others[i] + filter.responseDB(at: f[i]) - desired.db[i]
                        c += weights[i] * e * e
                    }
                    return c
                }
                var a = floorGain, b = lowest
                let phi = (sqrt(5.0) - 1) / 2
                var c = b - phi * (b - a), d = a + phi * (b - a)
                var fc = cost(c), fd = cost(d)
                for _ in 0..<30 {
                    if fc < fd { b = d; d = c; fd = fc; c = b - phi * (b - a); fc = cost(c) } else { a = c; c = d; fc = fd; d = a + phi * (b - a); fd = cost(d) }
                }
                let best = (a + b) / 2
                if abs(best - g[k]) > 0.01 { changed = true }
                g[k] = best
            }
            if !changed { break }
        }
        return g.map { gain.quantize(min(0, $0)) }
    }

    /// Greedy parametric fit: repeatedly place a cut on the largest remaining
    /// excess. For receivers with parametric EQ (not used by the TX-RZ50).
    public static func fitParametric(desired: FrequencyResponse, weights: [Double], maxFilters: Int, gain: ControlRange, qRange: ClosedRange<Double> = 0.5...10) -> [PeakingFilter] {
        var residual = desired.db
        var filters: [PeakingFilter] = []
        let f = desired.frequencies
        for _ in 0..<maxFilters {
            guard let i = f.indices.filter({ weights[$0] > 0 }).min(by: { residual[$0] < residual[$1] }), residual[i] < -1 else { break }
            let depth = residual[i]
            let half = depth / 2
            var lo = i, hi = i
            while lo > 0 && residual[lo] < half { lo -= 1 }
            while hi < f.count - 1 && residual[hi] < half { hi += 1 }
            let q = min(qRange.upperBound, max(qRange.lowerBound, f[i] / max(f[hi] - f[lo], 1e-6)))
            let filter = PeakingFilter(frequency: f[i], gainDB: gain.quantize(max(gain.min, depth)), q: q)
            filters.append(filter)
            for j in f.indices { residual[j] -= filter.responseDB(at: f[j]) }
        }
        return filters
    }
}
