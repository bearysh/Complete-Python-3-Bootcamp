import AVFoundation
import SignalKit

/// Plays a stereo stimulus over the current output (the receiver, via A2DP)
/// while recording the built-in mic. Never assumes playback/record alignment:
/// SignalKit recovers timing from the markers in the stimulus.
final class MeasurementEngine {
    struct Recording {
        var samples: [Float]
        var sampleRate: Double
    }

    enum EngineError: LocalizedError {
        case noInput
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .noInput: "The microphone isn't available."
            case .formatUnavailable: "The audio route isn't ready yet."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var captured: [Float] = []

    init() {
        engine.attach(player)
    }

    /// Sample rate the stimulus should be rendered at (the output hardware rate).
    var outputSampleRate: Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : 48_000
    }

    /// Plays `left`/`right` and returns everything the mic heard, plus `extra` seconds.
    func run(left: [Float], right: [Float], sampleRate: Double, extra: Double = 2.5, progress: (@MainActor (Double) -> Void)? = nil) async throws -> Recording {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(left.count)) else {
            throw EngineError.formatUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { src in buffer.floatChannelData![1].update(from: src.baseAddress!, count: right.count) }

        engine.connect(player, to: engine.mainMixerNode, format: stereo)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw EngineError.noInput }

        lock.lock(); captured = []; captured.reserveCapacity(Int((Double(left.count) / sampleRate + extra) * inFormat.sampleRate)); lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4_096, format: inFormat) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            self.lock.lock()
            self.captured.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            self.lock.unlock()
        }
        defer {
            input.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }

        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()

        let total = Double(left.count) / sampleRate + extra
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= total { break }
            if let progress { await progress(min(1, elapsed / total)) }
            try await Task.sleep(for: .milliseconds(100))
        }
        lock.lock(); let samples = captured; lock.unlock()
        return Recording(samples: samples, sampleRate: inFormat.sampleRate)
    }
}

/// Live input level meter, optionally playing a looped signal at the same time
/// (pink noise for the volume check).
final class LiveMeter {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var pending: [Float] = []
    private(set) var sampleRate: Double = 48_000
    private var running = false

    init() {
        engine.attach(player)
    }

    /// Starts listening. `onBlock` receives ~100 ms blocks on the main actor.
    func start(playing loop: [Float]? = nil, onBlock: @escaping @MainActor ([Float], Double) -> Void) throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MeasurementEngine.EngineError.noInput }
        sampleRate = format.sampleRate
        let block = Int(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            self.lock.lock()
            self.pending.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            var blocks: [[Float]] = []
            while self.pending.count >= block {
                blocks.append(Array(self.pending.prefix(block)))
                self.pending.removeFirst(block)
            }
            self.lock.unlock()
            let rate = format.sampleRate
            for b in blocks { Task { @MainActor in onBlock(b, rate) } }
        }
        if let loop {
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if let stereo = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2),
               let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(loop.count)) {
                buffer.frameLength = AVAudioFrameCount(loop.count)
                loop.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress!, count: loop.count)
                    buffer.floatChannelData![1].update(from: src.baseAddress!, count: loop.count)
                }
                engine.connect(player, to: engine.mainMixerNode, format: stereo)
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
        }
        engine.prepare()
        try engine.start()
        if loop != nil { player.play() }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.lock(); pending.removeAll(); lock.unlock()
        running = false
    }

    deinit { stop() }
}
