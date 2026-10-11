import Foundation

/// Regularised spectral deconvolution (Kirkeby-style):
/// H = Y·X* / (|X|² + ε(f)), with ε small inside the sweep band and large outside,
/// so out-of-band noise is not amplified.
public struct Deconvolver: Sendable {
    public let size: Int
    public let sampleRate: Double
    /// The regularised inverse filter G = X* / (|X|² + ε).
    let inverse: Spectrum

    /// - Parameters:
    ///   - stimulus: the exact signal that was played.
    ///   - signalLength: the longest recorded segment that will be deconvolved.
    ///   - band: frequencies the stimulus actually covers.
    public init(stimulus: [Double], signalLength: Int, sampleRate: Double, band: ClosedRange<Double>) {
        let n = FFT.nextPowerOfTwo(max(signalLength, stimulus.count) + stimulus.count)
        size = n
        self.sampleRate = sampleRate
        let x = FFT.forward(stimulus, size: n)
        let p = x.power
        let maxPower = p.max() ?? 1
        var g = Spectrum(count: n)
        let binHz = sampleRate / Double(n)
        for k in 0..<n {
            let bin = k <= n / 2 ? k : n - k
            let f = Double(bin) * binHz
            let w = Deconvolver.bandWeight(f, band: band)
            let eps = maxPower * (1e-7 * w + 1.0 * (1 - w))
            let d = p[k] + eps
            g.real[k] = x.real[k] / d
            g.imag[k] = -x.imag[k] / d
        }
        inverse = g
    }

    /// 1 inside the band, falling to 0 over half an octave outside it.
    static func bandWeight(_ f: Double, band: ClosedRange<Double>) -> Double {
        guard f > 0 else { return 0 }
        let lo = band.lowerBound, hi = band.upperBound
        if f >= lo && f <= hi { return 1 }
        let octaves = f < lo ? log2(lo / f) : log2(f / hi)
        if octaves >= 0.5 { return 0 }
        return 0.5 + 0.5 * cos(Double.pi * octaves / 0.5)
    }

    /// Impulse response of `recorded` (length `size`, circular). The linear response
    /// starts at the sample where the stimulus started in `recorded`; harmonic
    /// distortion products wrap to the end of the buffer (negative time).
    public func impulseResponse(of recorded: [Double]) -> [Double] {
        let y = FFT.forward(recorded, size: size)
        var h = Spectrum(count: size)
        for k in 0..<size {
            h.real[k] = y.real[k] * inverse.real[k] - y.imag[k] * inverse.imag[k]
            h.imag[k] = y.real[k] * inverse.imag[k] + y.imag[k] * inverse.real[k]
        }
        return FFT.inverseReal(h)
    }

    /// Noise floor expressed in the same units as a deconvolved, windowed response.
    ///
    /// A noise-only recording of length `m` is scaled up to the length of a full
    /// sweep segment, passed through the inverse filter, and reduced by the fraction
    /// of the IR that the analysis window keeps (noise spreads evenly over the IR).
    public func noisePower(noise: [Double], segmentLength: Int, windowLength: Int) -> (power: [Double], binHz: Double) {
        let m = max(noise.count, 1)
        let nfft = FFT.forward(noise, size: size)
        let scale = Double(segmentLength) / Double(m) * Double(windowLength) / Double(size)
        var out = [Double](repeating: 0, count: size / 2 + 1)
        for k in 0...(size / 2) {
            let gp = inverse.real[k] * inverse.real[k] + inverse.imag[k] * inverse.imag[k]
            let np = nfft.real[k] * nfft.real[k] + nfft.imag[k] * nfft.imag[k]
            out[k] = np * gp * scale
        }
        return (out, sampleRate / Double(size))
    }
}
