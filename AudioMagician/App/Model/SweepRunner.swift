import Foundation
import Observation
import SignalKit

/// Runs one full sweep program at a seat, with quality checks and quiet retries.
@MainActor
@Observable
final class SweepRunner {
    enum Phase: Equatable {
        case idle
        case listeningToRoom
        case playing(channel: SweepChannel)
        case analyzing
        case done
        case problem(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var attempt = 0
    private(set) var lastResult: ProgramResult?

    let maxAttempts = 3
    @ObservationIgnored private let engine = MeasurementEngine()

    /// Sweep settings. 6 s per sweep keeps a seat to ~25 s while keeping good SNR.
    func program() -> MeasurementProgram {
        let rate = engine.outputSampleRate
        return MeasurementProgram(sweep: SweepParameters(startFrequency: 10, endFrequency: 20_000, duration: 6, sampleRate: rate, amplitude: 0.5))
    }

    /// Measures; retries automatically on recoverable problems.
    func measure() async -> ProgramResult? {
        for n in 1...maxAttempts {
            attempt = n
            if let r = await measureOnce() { return r }
            if case .problem(let msg) = phase, msg.hasPrefix("Too loud") { return nil }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    private func measureOnce() async -> ProgramResult? {
        let program = program()
        let (left, right) = program.render()
        phase = .listeningToRoom
        progress = 0
        let duration = program.duration + 2.5
        do {
            let rec = try await engine.run(left: left, right: right, sampleRate: program.sampleRate) { [weak self] p in
                guard let self else { return }
                self.progress = p
                let t = p * duration
                self.phase = Self.phase(at: t, program: program)
            }
            phase = .analyzing
            let result = try await Task.detached(priority: .userInitiated) {
                try SweepAnalyzer.analyze(recording: rec.samples, recordingRate: rec.sampleRate, program: program)
            }.value
            lastResult = result
            if result.clipped {
                phase = .problem("Too loud: the microphone was overloaded. Turn the volume down a few steps and try again.")
                return nil
            }
            let snr = result.sweeps.map { s in s.response.meanLevel(in: 200...2_000) - s.noiseFloor.meanLevel(in: 200...2_000) }.min() ?? 0
            if snr < 20 {
                phase = .problem("A bit too quiet to hear clearly. Turn the volume up a little, or pause any noisy appliances.")
                return nil
            }
            phase = .done
            return result
        } catch SweepAnalyzer.Failure.markerNotFound(_) {
            phase = .problem("We couldn't hear the receiver. Check it's on the Bluetooth input and the volume is up.")
        } catch {
            phase = .problem(error.localizedDescription)
        }
        return nil
    }

    /// Approximate phase from elapsed time (Bluetooth latency ~0.2 s ignored for display).
    static func phase(at t: Double, program: MeasurementProgram) -> Phase {
        let fs = program.sampleRate
        if t < Double(program.markerAStart) / fs { return .listeningToRoom }
        for (i, ch) in program.channels.enumerated() {
            let start = Double(program.sweepStart(index: i)) / fs
            let end = start + program.sweep.duration + program.tail
            if t >= start - 0.8 && t < end { return .playing(channel: ch) }
        }
        return .analyzing
    }
}
