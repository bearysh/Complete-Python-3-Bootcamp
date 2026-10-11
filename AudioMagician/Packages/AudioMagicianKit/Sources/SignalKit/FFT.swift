import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Split-complex spectrum (separate real and imaginary arrays, vDSP style).
public struct Spectrum: Sendable {
    public var real: [Double]
    public var imag: [Double]

    public var count: Int { real.count }

    public init(real: [Double], imag: [Double]) {
        precondition(real.count == imag.count, "real/imag length mismatch")
        self.real = real
        self.imag = imag
    }

    public init(count: Int) {
        real = [Double](repeating: 0, count: count)
        imag = [Double](repeating: 0, count: count)
    }

    /// |X[k]|^2 for every bin.
    public var power: [Double] {
        var out = [Double](repeating: 0, count: count)
        for k in 0..<count { out[k] = real[k] * real[k] + imag[k] * imag[k] }
        return out
    }
}

/// Complex FFT on power-of-two sizes. Uses vDSP's DFT where available and a
/// plain radix-2 fallback elsewhere, so the maths is identical on any platform.
public enum FFT {
    public static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// Forward transform of a real signal, zero-padded (or truncated) to `size`.
    public static func forward(_ x: [Double], size: Int) -> Spectrum {
        var re = [Double](repeating: 0, count: size)
        let n = min(x.count, size)
        if n > 0 { re.replaceSubrange(0..<n, with: x[0..<n]) }
        return transform(Spectrum(real: re, imag: [Double](repeating: 0, count: size)), inverse: false)
    }

    /// Inverse transform, returning the real part scaled by 1/N.
    public static func inverseReal(_ s: Spectrum) -> [Double] {
        let out = transform(s, inverse: true)
        let scale = 1.0 / Double(s.count)
        return out.real.map { $0 * scale }
    }

    public static func transform(_ s: Spectrum, inverse: Bool) -> Spectrum {
        let n = s.count
        precondition(n > 0 && n & (n - 1) == 0, "FFT size must be a power of two")
        #if canImport(Accelerate)
        if n >= 16, let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(n), inverse ? .INVERSE : .FORWARD) {
            defer { vDSP_DFT_DestroySetupD(setup) }
            var outRe = [Double](repeating: 0, count: n)
            var outIm = [Double](repeating: 0, count: n)
            s.real.withUnsafeBufferPointer { ir in
                s.imag.withUnsafeBufferPointer { ii in
                    outRe.withUnsafeMutableBufferPointer { or in
                        outIm.withUnsafeMutableBufferPointer { oi in
                            vDSP_DFT_ExecuteD(setup, ir.baseAddress!, ii.baseAddress!, or.baseAddress!, oi.baseAddress!)
                        }
                    }
                }
            }
            return Spectrum(real: outRe, imag: outIm)
        }
        #endif
        return radix2(s, inverse: inverse)
    }

    static func radix2(_ s: Spectrum, inverse: Bool) -> Spectrum {
        let n = s.count
        guard n > 1 else { return s }
        var re = s.real
        var im = s.imag
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        let sign: Double = inverse ? 1 : -1
        var len = 2
        while len <= n {
            let half = len / 2
            let angle = sign * 2 * Double.pi / Double(len)
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cos(angle * Double(k))
                    let wi = sin(angle * Double(k))
                    let a = start + k
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        return Spectrum(real: re, imag: im)
    }
}
