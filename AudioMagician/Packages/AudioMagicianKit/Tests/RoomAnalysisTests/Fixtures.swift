import Foundation
import SignalKit
import ReceiverKit
@testable import RoomAnalysis

enum Fixtures {
    static let grid = LogGrid.standard

    /// A response that's flat at `level` plus Gaussian-in-log-frequency bumps.
    static func response(level: Double = -20, bumps: [(f: Double, dB: Double, octaves: Double)] = []) -> FrequencyResponse {
        FrequencyResponse(frequencies: grid, db: grid.map { f in
            level + bumps.reduce(0) { acc, b in
                let x = log2(f / b.f) / b.octaves
                return acc + b.dB * exp(-x * x)
            }
        })
    }

    static func sweep(_ c: SweepChannel, _ r: FrequencyResponse) -> SweepResult {
        SweepResult(
            channel: c,
            response: r,
            noiseFloor: FrequencyResponse(frequencies: grid, db: grid.map { _ in -90 }),
            arrival: 0,
            decay: [DecayBand(center: 500, t20: 0.4, edt: 0.35), DecayBand(center: 1_000, t20: 0.4, edt: 0.35)],
            impulsePreview: [],
            impulsePreviewRate: 4_800
        )
    }

    static func seat(_ id: Int, _ r: FrequencyResponse) -> SeatMeasurement {
        SeatMeasurement(id: id, program: ProgramResult(
            sweeps: [sweep(.left, r.offset(by: -3)), sweep(.right, r.offset(by: -3)), sweep(.both, r)],
            clockRatio: 1, latency: 0.2, peakInputLevel: 0.3, noiseFloorDBFS: -80
        ))
    }

    static let setup = RoomSetup(receiverID: "onkyo-tx-rz50", layout: SpeakerLayout.presets[2], speakerSize: .bookshelf, correction: .turnOff)
}
