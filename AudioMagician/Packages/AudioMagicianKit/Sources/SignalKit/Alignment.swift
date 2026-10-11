import Foundation

/// Locates known marker chirps in a recording and corrects clock drift.
///
/// Bluetooth adds an unknown, variable delay, and the receiver's DAC clock is not
/// locked to the phone's microphone clock. We play a short chirp before and after
/// the sweeps; the distance between their arrivals, compared with the distance we
/// scheduled, gives the combined sample-rate ratio (drift plus any nominal rate
/// mismatch). The recording is then resampled onto the stimulus timebase.
public enum Alignment {
    public struct MarkerHit: Sendable, Equatable {
        /// Fractional sample index in the recording where the marker starts.
        public var position: Double
        /// Matched-filter peak relative to the median correlation level, dB.
        public var prominenceDB: Double
    }

    public enum Failure: Error, Equatable, Sendable {
        case markerNotFound(which: String)
        case implausibleDrift(ratio: Double)
    }

    /// Short linear chirp used as a timing marker.
    public static func marker(sampleRate: Double, duration: Double = 0.25, from f0: Double = 800, to f1: Double = 6_000, amplitude: Double = 0.5) -> [Double] {
        let n = Int(duration * sampleRate)
        var out = [Double](repeating: 0, count: n)
        let k = (f1 - f0) / duration
        for i in 0..<n {
            let t = Double(i) / sampleRate
            out[i] = amplitude * sin(2 * Double.pi * (f0 * t + 0.5 * k * t * t))
        }
        Window.applyFades(&out, fadeIn: n / 8, fadeOut: n / 8)
        return out
    }

    /// Cross-correlation of `signal` with `template` via FFT. Index i is the
    /// correlation at lag i (template starting at signal[i]).
    public static func correlate(_ signal: [Double], with template: [Double]) -> [Double] {
        let n = FFT.nextPowerOfTwo(signal.count + template.count)
        let s = FFT.forward(signal, size: n)
        let t = FFT.forward(template, size: n)
        var c = Spectrum(count: n)
        for k in 0..<n {
            // S · conj(T)
            c.real[k] = s.real[k] * t.real[k] + s.imag[k] * t.imag[k]
            c.imag[k] = s.imag[k] * t.real[k] - s.real[k] * t.imag[k]
        }
        let full = FFT.inverseReal(c)
        return Array(full[0..<signal.count])
    }

    /// Strongest marker match inside `range` of the recording.
    public static func findMarker(in recording: [Double], template: [Double], searchRange: Range<Int>) -> MarkerHit? {
        let lo = max(0, searchRange.lowerBound)
        let hi = min(recording.count, searchRange.upperBound + template.count)
        guard hi - lo > template.count else { return nil }
        let slice = Array(recording[lo..<hi])
        let corr = correlate(slice, with: template).map(abs)
        let usable = corr.count - template.count + 1
        guard usable > 2 else { return nil }
        var best = 0
        for i in 0..<usable where corr[i] > corr[best] { best = i }
        let sorted = corr[0..<usable].sorted()
        let median = max(sorted[sorted.count / 2], 1e-12)
        let prominence = 20 * log10(corr[best] / median)
        // Parabolic interpolation around the peak for sub-sample precision.
        var offset = 0.0
        if best > 0 && best < usable - 1 {
            let a = corr[best - 1], b = corr[best], c = corr[best + 1]
            let denom = a - 2 * b + c
            if denom != 0 { offset = 0.5 * (a - c) / denom }
        }
        return MarkerHit(position: Double(lo + best) + offset, prominenceDB: prominence)
    }

    /// Windowed-sinc (Lanczos) interpolation of `x` at fractional index `t`.
    @inline(__always)
    static func interpolate(_ x: UnsafeBufferPointer<Double>, at t: Double, a: Int = 8) -> Double {
        let base = Int(floor(t))
        let frac = t - Double(base)
        if frac == 0, base >= 0, base < x.count { return x[base] }
        var sum = 0.0
        for j in (base - a + 1)...(base + a) {
            guard j >= 0 && j < x.count else { continue }
            let d = t - Double(j)
            let pd = Double.pi * d
            let w = (sin(pd) / pd) * (sin(pd / Double(a)) / (pd / Double(a)))
            sum += x[j] * w
        }
        return sum
    }

    /// Resamples `recording` so that recording position `anchor + (i - nominalAnchor) * ratio`
    /// lands on output index i, for i in 0..<outputLength.
    public static func resample(_ recording: [Double], anchor: Double, nominalAnchor: Double, ratio: Double, outputLength: Int) -> [Double] {
        var out = [Double](repeating: 0, count: outputLength)
        recording.withUnsafeBufferPointer { buf in
            for i in 0..<outputLength {
                let t = anchor + (Double(i) - nominalAnchor) * ratio
                if t < -1 || t > Double(buf.count) { continue }
                out[i] = interpolate(buf, at: t)
            }
        }
        return out
    }
}
