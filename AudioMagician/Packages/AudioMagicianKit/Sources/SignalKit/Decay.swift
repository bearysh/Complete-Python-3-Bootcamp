import Foundation

public struct DecayBand: Codable, Sendable, Equatable {
    /// Octave band centre, Hz.
    public var center: Double
    /// Reverberation time extrapolated to 60 dB from the -5…-25 dB slope (T20), seconds.
    public var t20: Double
    /// Early decay time (0…-10 dB slope ×6), seconds.
    public var edt: Double

    public init(center: Double, t20: Double, edt: Double) {
        self.center = center
        self.t20 = t20
        self.edt = edt
    }
}

/// Reverberation-time estimates from an impulse response (ISO 3382 style, simplified).
public enum Decay {
    public static let octaveCenters: [Double] = [63, 125, 250, 500, 1_000, 2_000, 4_000]

    /// `ir` should start at the direct sound.
    public static func octaveBands(_ ir: [Double], sampleRate fs: Double, centers: [Double] = octaveCenters) -> [DecayBand] {
        guard ir.count > Int(0.1 * fs) else { return [] }
        let n = FFT.nextPowerOfTwo(ir.count)
        let spec = FFT.forward(ir, size: n)
        let binHz = fs / Double(n)
        return centers.compactMap { fc in
            var band = Spectrum(count: n)
            for k in 0..<n {
                let bin = k <= n / 2 ? k : n - k
                let f = Double(bin) * binHz
                guard f > 0 else { continue }
                // Smooth octave-wide passband (cosine skirts over a third of an octave).
                let octs = abs(log2(f / fc))
                let w: Double = octs <= 0.5 ? 1 : (octs >= 0.8333 ? 0 : 0.5 + 0.5 * cos(Double.pi * (octs - 0.5) / 0.3333))
                band.real[k] = spec.real[k] * w
                band.imag[k] = spec.imag[k] * w
            }
            let filtered = Array(FFT.inverseReal(band)[0..<ir.count])
            return estimate(filtered, sampleRate: fs, center: fc)
        }
    }

    /// Schroeder backward integration with a simple noise-floor truncation.
    static func estimate(_ x: [Double], sampleRate fs: Double, center: Double) -> DecayBand? {
        let energy = x.map { $0 * $0 }
        // Truncate where the 10 ms envelope meets the noise floor (mean of the last 10 %).
        let tailStart = Int(Double(energy.count) * 0.9)
        let noise = energy[tailStart...].reduce(0, +) / Double(energy.count - tailStart)
        let block = max(1, Int(0.01 * fs))
        var cut = energy.count
        var i = 0
        var seenSignal = false
        while i + block <= tailStart {
            let mean = energy[i..<(i + block)].reduce(0, +) / Double(block)
            if mean > noise * 10 { seenSignal = true }
            if seenSignal && mean < noise * 2 { cut = i; break }
            i += block
        }
        guard cut > block * 5 else { return nil }
        var edc = [Double](repeating: 0, count: cut)
        var acc = 0.0
        for j in stride(from: cut - 1, through: 0, by: -1) {
            acc += energy[j]
            edc[j] = acc
        }
        guard let total = edc.first, total > 0 else { return nil }
        let edcDB = edc.map { 10 * log10(max($0 / total, 1e-30)) }
        guard let t20 = slope(edcDB, from: -5, to: -25, fs: fs), let edt = slope(edcDB, from: 0, to: -10, fs: fs) else { return nil }
        return DecayBand(center: center, t20: t20, edt: edt)
    }

    /// Least-squares fit between two EDC levels, extrapolated to -60 dB.
    static func slope(_ edc: [Double], from top: Double, to bottom: Double, fs: Double) -> Double? {
        guard let i0 = edc.firstIndex(where: { $0 <= top }), let i1 = edc.firstIndex(where: { $0 <= bottom }), i1 > i0 + 2 else { return nil }
        let n = Double(i1 - i0)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in i0..<i1 {
            let t = Double(i) / fs
            sx += t; sy += edc[i]; sxx += t * t; sxy += t * edc[i]
        }
        let denom = n * sxx - sx * sx
        guard denom != 0 else { return nil }
        let m = (n * sxy - sx * sy) / denom
        guard m < 0 else { return nil }
        return -60 / m
    }
}
