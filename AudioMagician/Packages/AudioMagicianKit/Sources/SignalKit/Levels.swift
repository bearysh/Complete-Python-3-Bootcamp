import Foundation

public enum Levels {
    /// RMS level of a block, dB re. full scale.
    public static func rmsDB(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return -160 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return 10 * log10(max(acc / Double(x.count), 1e-16))
    }

    /// Level of the energy inside `band`, dB re. full scale. Uses a Hann-windowed
    /// FFT of the block, so steady broadband noise reads the same at any block size.
    public static func bandLevelDB(_ x: [Float], sampleRate: Double, band: ClosedRange<Double>) -> Double {
        guard x.count >= 64 else { return -160 }
        let n = FFT.nextPowerOfTwo(x.count)
        let w = Window.hann(x.count)
        let windowed = zip(x, w).map { Double($0) * $1 }
        let p = FFT.forward(windowed, size: n).power
        let binHz = sampleRate / Double(n)
        let lo = max(1, Int(ceil(band.lowerBound / binHz)))
        let hi = min(n / 2, Int(floor(band.upperBound / binHz)))
        guard hi >= lo else { return -160 }
        let windowPower = w.reduce(0) { $0 + $1 * $1 }
        // Parseval: one-sided band energy over window energy → mean square in band.
        let energy = p[lo...hi].reduce(0, +) * 2 / Double(n)
        return 10 * log10(max(energy / windowPower, 1e-16))
    }
}

/// Detects a steady receiver test tone in a stream of level readings and reports
/// its level once it has held still long enough.
///
/// Feed it one reading per block (e.g. every 100 ms). Pure value type so the logic
/// is unit-testable without audio hardware.
public struct ToneSegmenter: Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case settling(progress: Double)
        case measured(levelDB: Double)
    }

    public var noiseFloorDB: Double
    /// How far above the noise floor a tone must be.
    public var threshold: Double = 10
    /// Readings must stay within ± this of their median.
    public var tolerance: Double = 1.5
    /// Number of consecutive steady readings needed.
    public var requiredReadings: Int = 20

    private var window: [Double] = []
    public private(set) var state: State = .waiting

    public init(noiseFloorDB: Double, requiredReadings: Int = 20) {
        self.noiseFloorDB = noiseFloorDB
        self.requiredReadings = requiredReadings
    }

    public mutating func reset() {
        window.removeAll()
        state = .waiting
    }

    @discardableResult
    public mutating func feed(_ levelDB: Double) -> State {
        if case .measured = state { return state }
        guard levelDB > noiseFloorDB + threshold else {
            window.removeAll()
            state = .waiting
            return state
        }
        window.append(levelDB)
        let median = window.sorted()[window.count / 2]
        // Drop readings from the front until everything left is steady.
        while let first = window.first, abs(first - median) > tolerance { window.removeFirst() }
        if window.count >= requiredReadings {
            let sorted = window.suffix(requiredReadings).sorted()
            state = .measured(levelDB: sorted[sorted.count / 2])
        } else {
            state = .settling(progress: Double(window.count) / Double(requiredReadings))
        }
        return state
    }
}

public enum PinkNoise {
    /// Pink noise (Paul Kellet's refined filter), normalised to `rmsDB` dBFS.
    public static func generate(count: Int, rmsDB: Double = -20, seed: UInt64 = 0x5EED) -> [Float] {
        var rng = SplitMix64(seed: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var out = [Float](repeating: 0, count: count)
        var acc = 0.0
        for i in 0..<count {
            let white = rng.nextUniform() * 2 - 1
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let v = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            out[i] = Float(v)
            acc += v * v
        }
        let rms = sqrt(acc / Double(max(count, 1)))
        let gain = Float(pow(10, rmsDB / 20) / max(rms, 1e-12))
        for i in 0..<count { out[i] *= gain }
        // Short fades so looping playback doesn't click.
        let fade = min(count / 2, 480)
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            out[i] *= g
            out[count - 1 - i] *= g
        }
        return out
    }
}

/// Small deterministic RNG so generated signals are reproducible.
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextUniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-300), u2 = nextUniform()
        return sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2)
    }
}
