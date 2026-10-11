import Foundation

/// One deconvolved sweep.
public struct SweepResult: Codable, Sendable, Equatable {
    public var channel: SweepChannel
    /// Raw (uncalibrated) magnitude response, 1/48-octave smoothed, dB re. full scale.
    public var response: FrequencyResponse
    /// Noise floor on the same grid and in the same units as `response`.
    public var noiseFloor: FrequencyResponse
    /// Arrival time of the direct sound relative to marker A's arrival, seconds.
    /// Only differences between sweeps of the same program are meaningful.
    public var arrival: Double
    /// Reverberation time per octave band (centre Hz → seconds), when measurable.
    public var decay: [DecayBand]
    /// Impulse response around the direct sound (decimated for display), with its rate.
    public var impulsePreview: [Float]
    public var impulsePreviewRate: Double

    public init(channel: SweepChannel, response: FrequencyResponse, noiseFloor: FrequencyResponse, arrival: Double, decay: [DecayBand], impulsePreview: [Float], impulsePreviewRate: Double) {
        self.channel = channel
        self.response = response
        self.noiseFloor = noiseFloor
        self.arrival = arrival
        self.decay = decay
        self.impulsePreview = impulsePreview
        self.impulsePreviewRate = impulsePreviewRate
    }

    /// Signal-to-noise ratio at each grid point.
    public var snrDB: [Double] { zip(response.db, noiseFloor.db).map { $0 - $1 } }
}

public struct ProgramResult: Codable, Sendable, Equatable {
    public var sweeps: [SweepResult]
    /// Recording-samples per stimulus-sample, from the markers (drift + rate mismatch).
    public var clockRatio: Double
    public var latency: Double
    public var peakInputLevel: Double
    public var noiseFloorDBFS: Double

    public init(sweeps: [SweepResult], clockRatio: Double, latency: Double, peakInputLevel: Double, noiseFloorDBFS: Double) {
        self.sweeps = sweeps
        self.clockRatio = clockRatio
        self.latency = latency
        self.peakInputLevel = peakInputLevel
        self.noiseFloorDBFS = noiseFloorDBFS
    }

    public var clipped: Bool { peakInputLevel >= 0.98 }
    public var driftPPM: Double { (clockRatio - 1) * 1_000_000 }

    public func sweep(_ c: SweepChannel) -> SweepResult? { sweeps.first { $0.channel == c } }
}

public enum SweepAnalyzer {
    public enum Failure: Error, Equatable, Sendable {
        case markerNotFound(String)
        case implausibleClock(Double)
        case recordingTooShort
    }

    public struct Options: Sendable {
        /// Length of the IR kept for the frequency response. 500 ms gives ~2 Hz resolution.
        public var responseWindow: Double = 0.5
        /// Pre-roll before the direct sound kept in the window.
        public var preWindow: Double = 0.005
        public var grid: [Double] = LogGrid.standard
        public var smoothing: Double = 48
        public init() {}
    }

    /// Analyses a mono recording of `program` captured at `recordingRate`.
    public static func analyze(recording raw: [Float], recordingRate: Double, program: MeasurementProgram, options: Options = Options()) throws -> ProgramResult {
        let rec = raw.map(Double.init)
        let fs = program.sampleRate
        let nominalRatio = recordingRate / fs
        guard Double(rec.count) > Double(program.markerBStart) * nominalRatio * 0.9 else { throw Failure.recordingTooShort }
        let template = Alignment.marker(sampleRate: recordingRate, duration: program.markerDuration)

        // Marker A: somewhere after the scheduled time (latency is positive, up to ~1.5 s).
        let aNominal = Double(program.markerAStart) * nominalRatio
        let aRange = Int(aNominal * 0.5)..<Int(aNominal + 2.0 * recordingRate)
        guard let a = Alignment.findMarker(in: rec, template: template, searchRange: aRange), a.prominenceDB > 12 else {
            throw Failure.markerNotFound("start")
        }
        // Marker B: expected spacing ± 2 %.
        let spacing = Double(program.markerBStart - program.markerAStart) * nominalRatio
        let bExpected = a.position + spacing
        let bRange = Int(bExpected - spacing * 0.02 - recordingRate * 0.05)..<Int(bExpected + spacing * 0.02 + recordingRate * 0.05)
        guard let b = Alignment.findMarker(in: rec, template: template, searchRange: bRange), b.prominenceDB > 12 else {
            throw Failure.markerNotFound("end")
        }
        let ratio = (b.position - a.position) / Double(program.markerBStart - program.markerAStart)
        guard abs(ratio / nominalRatio - 1) < 0.01 else { throw Failure.implausibleClock(ratio) }

        // Put the whole recording on the stimulus timebase.
        let aligned = Alignment.resample(rec, anchor: a.position, nominalAnchor: Double(program.markerAStart), ratio: ratio, outputLength: program.totalLength)

        let sweep = ExponentialSweep.generate(program.sweep)
        let preRoll = Int(0.1 * fs)
        let segmentLength = preRoll + sweep.count + Int(program.tail * fs)
        let band = program.sweep.startFrequency...program.sweep.endFrequency
        let deconvolver = Deconvolver(stimulus: sweep, signalLength: segmentLength, sampleRate: fs, band: band)

        let noise = Array(aligned[program.noiseRange])
        let windowLength = Int(options.responseWindow * fs)
        // Effective length of the analysis window (Tukey: 80 % flat, 20 % taper).
        let effectiveWindow = Int(Double(windowLength) * 0.9)
        let noiseSpectrum = deconvolver.noisePower(noise: noise, segmentLength: segmentLength, windowLength: effectiveWindow)
        let noiseDB = Smoothing.fractionalOctave(power: noiseSpectrum.power, binHz: noiseSpectrum.binHz, grid: options.grid, fraction: options.smoothing)
        let noiseFloor = FrequencyResponse(frequencies: options.grid, db: noiseDB)

        var results: [SweepResult] = []
        for (i, channel) in program.channels.enumerated() {
            let start = program.sweepStart(index: i) - preRoll
            let end = min(aligned.count, start + segmentLength)
            let segment = Array(aligned[start..<end])
            let ir = deconvolver.impulseResponse(of: segment)
            let causal = Array(ir[0..<min(ir.count, segmentLength)])
            results.append(analyzeIR(causal, preRoll: preRoll, channel: channel, sampleRate: fs, noiseFloor: noiseFloor, options: options))
        }

        let peak = Double(raw.map { abs($0) }.max() ?? 0)
        let noiseRMS = sqrt(noise.reduce(0) { $0 + $1 * $1 } / Double(max(noise.count, 1)))
        return ProgramResult(
            sweeps: results,
            clockRatio: ratio,
            latency: (a.position - aNominal) / recordingRate,
            peakInputLevel: peak,
            noiseFloorDBFS: 20 * log10(max(noiseRMS, 1e-12))
        )
    }

    static func analyzeIR(_ ir: [Double], preRoll: Int, channel: SweepChannel, sampleRate fs: Double, noiseFloor: FrequencyResponse, options: Options) -> SweepResult {
        // Direct sound: the largest peak near where the sweep started.
        let searchEnd = min(ir.count, preRoll + Int(0.3 * fs))
        var peak = preRoll
        for i in max(0, preRoll - Int(0.05 * fs))..<searchEnd where abs(ir[i]) > abs(ir[peak]) { peak = i }

        let pre = Int(options.preWindow * fs)
        let windowLength = Int(options.responseWindow * fs)
        let start = max(0, peak - pre)
        let end = min(ir.count, start + windowLength)
        var windowed = Array(ir[start..<end])
        let taper = windowed.count / 5
        Window.applyFades(&windowed, fadeIn: pre, fadeOut: taper)
        let nfft = FFT.nextPowerOfTwo(max(windowed.count, 1 << 15))
        let spec = FFT.forward(windowed, size: nfft)
        let power = Array(spec.power[0...(nfft / 2)])
        let db = Smoothing.fractionalOctave(power: power, binHz: fs / Double(nfft), grid: options.grid, fraction: options.smoothing)

        // Short preview for the Details view: 20 ms before to 200 ms after, at 4.8 kHz-ish.
        let pvStart = max(0, peak - Int(0.02 * fs))
        let pvEnd = min(ir.count, peak + Int(0.2 * fs))
        let step = max(1, Int(fs / 4_800))
        var preview: [Float] = []
        var j = pvStart
        while j < pvEnd { preview.append(Float(ir[j])); j += step }

        // Decay analysis: 2 s after the direct sound is plenty for living rooms and
        // leaves the last part as a noise reference.
        let tail = Array(ir[peak..<min(ir.count, peak + Int(2.0 * fs))])
        return SweepResult(
            channel: channel,
            response: FrequencyResponse(frequencies: options.grid, db: db),
            noiseFloor: noiseFloor,
            arrival: Double(peak - preRoll) / fs,
            decay: Decay.octaveBands(tail, sampleRate: fs),
            impulsePreview: preview,
            impulsePreviewRate: fs / Double(step)
        )
    }
}
