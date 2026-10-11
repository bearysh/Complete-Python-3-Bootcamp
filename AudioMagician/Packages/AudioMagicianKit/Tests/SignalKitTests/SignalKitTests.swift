import XCTest
@testable import SignalKit

final class FFTTests: XCTestCase {
    func testRoundTrip() {
        var rng = SplitMix64(seed: 1)
        let x = (0..<1024).map { _ in rng.nextGaussian() }
        let y = FFT.inverseReal(FFT.forward(x, size: 1024))
        for i in 0..<1024 { XCTAssertEqual(x[i], y[i], accuracy: 1e-9) }
    }

    func testAccelerateMatchesFallback() {
        var rng = SplitMix64(seed: 2)
        let s = Spectrum(real: (0..<256).map { _ in rng.nextGaussian() }, imag: (0..<256).map { _ in rng.nextGaussian() })
        let a = FFT.transform(s, inverse: false)
        let b = FFT.radix2(s, inverse: false)
        for k in 0..<256 {
            XCTAssertEqual(a.real[k], b.real[k], accuracy: 1e-8)
            XCTAssertEqual(a.imag[k], b.imag[k], accuracy: 1e-8)
        }
    }

    func testSineLandsInRightBin() {
        let n = 4096, fs = 48_000.0
        let f = fs / Double(n) * 100
        let x = (0..<n).map { sin(2 * Double.pi * f * Double($0) / fs) }
        let p = FFT.forward(x, size: n).power
        let peak = (1..<(n / 2)).max { p[$0] < p[$1] }
        XCTAssertEqual(peak, 100)
    }
}

final class ResponseTests: XCTestCase {
    func testGridAndInterpolation() {
        let g = LogGrid.make(from: 20, to: 20_000, pointsPerOctave: 3)
        XCTAssertEqual(g.first!, 20, accuracy: 1e-9)
        XCTAssertEqual(g.last!, 20_000 * pow(2, (log2(1000) * 3).rounded() / 3 - log2(1000)), accuracy: 1)
        let r = FrequencyResponse(frequencies: [100, 1000], db: [0, 10])
        XCTAssertEqual(r.value(at: sqrt(100 * 1000)), 5, accuracy: 1e-9)
        XCTAssertEqual(r.value(at: 10), 0)
    }

    func testSmoothingKeepsFlatFlat() {
        let g = LogGrid.make(pointsPerOctave: 24)
        let r = FrequencyResponse(frequencies: g, db: g.map { _ in -6 }).smoothed(fraction: 3)
        for v in r.db { XCTAssertEqual(v, -6, accuracy: 1e-9) }
    }

    func testAverageAndSpread() {
        let g = [100.0, 200]
        let a = FrequencyResponse(frequencies: g, db: [0, 0])
        let b = FrequencyResponse(frequencies: g, db: [0, -6])
        let (mean, spread) = Smoothing.average([a, b])!
        XCTAssertEqual(mean.db[0], 0, accuracy: 1e-9)
        XCTAssertEqual(spread[1], 3, accuracy: 1e-9)
        XCTAssertLessThan(mean.db[1], 0)
    }
}

final class MeasurementPipelineTests: XCTestCase {
    /// Simulates the whole chain: stereo stimulus → two speakers with different
    /// delays → mic mix → Bluetooth latency + clock drift → noise → analysis.
    func testRecoversDelayDriftAndFlatResponse() throws {
        let fs = 48_000.0
        let program = MeasurementProgram(
            sweep: SweepParameters(startFrequency: 20, endFrequency: 20_000, duration: 2, sampleRate: fs),
            preSilence: 1.0, tail: 0.6, postSilence: 0.3
        )
        let (l, r) = program.render()
        // Left speaker 3.0 ms away at gain 0.5, right speaker 5.5 ms at gain 0.25.
        let dl = Int(0.003 * fs), dr = Int(0.0055 * fs)
        var acoustic = [Double](repeating: 0, count: program.totalLength + 1_000)
        for i in 0..<program.totalLength {
            acoustic[i + dl] += 0.5 * Double(l[i])
            acoustic[i + dr] += 0.25 * Double(r[i])
        }
        // Bluetooth: 180 ms latency, recording clock 60 ppm fast.
        let latency = 0.18 * fs
        let ratio = 1 + 60e-6
        let recLength = Int(Double(acoustic.count) * ratio + latency) + 2_000
        // Recording sample j corresponds to acoustic sample (j - latency) / ratio.
        var recording = Alignment.resample(acoustic, anchor: -latency / ratio, nominalAnchor: 0, ratio: 1 / ratio, outputLength: recLength)
        var rng = SplitMix64(seed: 9)
        for i in recording.indices { recording[i] += 1e-4 * rng.nextGaussian() }

        let result = try SweepAnalyzer.analyze(recording: recording.map(Float.init), recordingRate: fs, program: program)

        XCTAssertEqual(result.driftPPM, 60, accuracy: 2)
        let left = try XCTUnwrap(result.sweep(.left))
        let right = try XCTUnwrap(result.sweep(.right))
        XCTAssertEqual(right.arrival - left.arrival, 0.0025, accuracy: 0.0002)

        // Pure delay + gain: flat at 20·log10(0.5) ≈ −6 dB across the band.
        for f in [100.0, 1_000, 5_000, 12_000] {
            XCTAssertEqual(left.response.value(at: f), -6.02, accuracy: 0.5, "left @ \(f) Hz")
            XCTAssertEqual(right.response.value(at: f), -12.04, accuracy: 0.5, "right @ \(f) Hz")
        }
        // Signal well above the noise floor in the middle of the band.
        let snrAt1k = left.response.value(at: 1_000) - left.noiseFloor.value(at: 1_000)
        XCTAssertGreaterThan(snrAt1k, 30)
        XCTAssertFalse(result.clipped)
    }

    func testMissingMarkerThrows() {
        let program = MeasurementProgram(sweep: SweepParameters(duration: 1), preSilence: 0.5, tail: 0.3)
        let silence = [Float](repeating: 0, count: program.totalLength + 10_000)
        XCTAssertThrowsError(try SweepAnalyzer.analyze(recording: silence, recordingRate: 48_000, program: program))
    }

    func testNoiseFloorTracksNoiseLevel() throws {
        let fs = 48_000.0
        let program = MeasurementProgram(sweep: SweepParameters(duration: 1.5, sampleRate: fs), preSilence: 1.0, tail: 0.5, postSilence: 0.3)
        func run(noise: Double) throws -> Double {
            let (l, r) = program.render()
            var rec = [Double](repeating: 0, count: program.totalLength + 20_000)
            var rng = SplitMix64(seed: 3)
            for i in 0..<program.totalLength { rec[i + 4_800] = 0.3 * Double(l[i] + r[i]) }
            for i in rec.indices { rec[i] += noise * rng.nextGaussian() }
            let res = try SweepAnalyzer.analyze(recording: rec.map(Float.init), recordingRate: fs, program: program)
            return res.sweeps[0].noiseFloor.value(at: 1_000)
        }
        let quiet = try run(noise: 1e-4)
        let loud = try run(noise: 1e-3)
        // 10× noise amplitude → +20 dB noise floor.
        XCTAssertEqual(loud - quiet, 20, accuracy: 2)
    }
}

final class DecayTests: XCTestCase {
    func testT20OfExponentialNoise() {
        let fs = 48_000.0, rt = 0.5
        var rng = SplitMix64(seed: 4)
        let n = Int(1.5 * fs)
        let ir = (0..<n).map { i -> Double in
            let t = Double(i) / fs
            return rng.nextGaussian() * pow(10, -3 * t / rt) + 1e-6 * rng.nextGaussian()
        }
        let bands = Decay.octaveBands(ir, sampleRate: fs, centers: [500, 1_000, 2_000])
        XCTAssertEqual(bands.count, 3)
        for b in bands { XCTAssertEqual(b.t20, rt, accuracy: 0.08, "band \(b.center)") }
    }
}

final class LevelTests: XCTestCase {
    func testBandLevelOfSine() {
        let fs = 48_000.0
        let x = (0..<8192).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / fs)) }
        // A 0.5-amplitude sine has mean square 0.125 → −9.03 dBFS.
        XCTAssertEqual(Levels.bandLevelDB(x, sampleRate: fs, band: 500...2_000), -9.03, accuracy: 0.3)
        XCTAssertLessThan(Levels.bandLevelDB(x, sampleRate: fs, band: 3_000...6_000), -40)
        XCTAssertEqual(Levels.rmsDB(x), -9.03, accuracy: 0.05)
    }

    func testPinkNoiseLevel() {
        let x = PinkNoise.generate(count: 48_000, rmsDB: -20)
        XCTAssertEqual(Levels.rmsDB(Array(x[1_000..<47_000])), -20, accuracy: 0.5)
    }

    func testToneSegmenter() {
        var seg = ToneSegmenter(noiseFloorDB: -70, requiredReadings: 5)
        XCTAssertEqual(seg.feed(-68), .waiting)
        XCTAssertEqual(seg.feed(-30), .settling(progress: 0.2))
        // A jump resets the run.
        _ = seg.feed(-20)
        for _ in 0..<4 { _ = seg.feed(-20.4) }
        XCTAssertEqual(seg.state, .measured(levelDB: -20.4))
    }

    func testPeakingFilterShape() {
        let f = PeakingFilter(frequency: 100, gainDB: -6, q: 2)
        XCTAssertEqual(f.responseDB(at: 100), -6, accuracy: 0.01)
        XCTAssertGreaterThan(f.responseDB(at: 1_000), -0.2)
    }
}
