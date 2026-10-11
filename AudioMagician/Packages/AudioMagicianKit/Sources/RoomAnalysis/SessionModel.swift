import Foundation
import SignalKit
import ReceiverKit

/// Everything the user told us about their setup.
public struct RoomSetup: Codable, Sendable, Equatable {
    public var receiverID: String
    public var layout: SpeakerLayout
    public var speakerSize: SpeakerSize
    public var correction: RoomCorrectionChoice
    /// Seat-to-speaker distances in metres (manual or camera), if provided.
    public var distances: [SpeakerChannel: Double]

    public init(receiverID: String, layout: SpeakerLayout, speakerSize: SpeakerSize = .bookshelf, correction: RoomCorrectionChoice = .turnOff, distances: [SpeakerChannel: Double] = [:]) {
        self.receiverID = receiverID
        self.layout = layout
        self.speakerSize = speakerSize
        self.correction = correction
        self.distances = distances
    }
}

/// Sweeps captured at one listening position.
public struct SeatMeasurement: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var program: ProgramResult

    public init(id: Int, program: ProgramResult) {
        self.id = id
        self.program = program
    }

    public var isMainSeat: Bool { id == 0 }
}

/// Test-tone level for each speaker, read at the main seat, dB re. full scale
/// (uncalibrated: only differences between channels are meaningful).
public struct ToneReading: Codable, Sendable, Equatable {
    public var channel: SpeakerChannel
    public var levelDB: Double
    /// The band the meter listened in.
    public var bandLow: Double
    public var bandHigh: Double

    public init(channel: SpeakerChannel, levelDB: Double, band: ClosedRange<Double>) {
        self.channel = channel
        self.levelDB = levelDB
        bandLow = band.lowerBound
        bandHigh = band.upperBound
    }

    public var band: ClosedRange<Double> { bandLow...bandHigh }

    /// The band to listen in for a channel: the sub's tone is low-pass noise.
    public static func band(for channel: SpeakerChannel) -> ClosedRange<Double> {
        channel.isSubwoofer ? 30...120 : 250...4_000
    }
}

public struct SessionData: Codable, Sendable, Equatable {
    public var setup: RoomSetup
    public var seats: [SeatMeasurement]
    public var tones: [ToneReading]
    /// The crossover frequency in use while measuring, if the user knows it.
    public var currentCrossover: Double?

    public init(setup: RoomSetup, seats: [SeatMeasurement] = [], tones: [ToneReading] = [], currentCrossover: Double? = nil) {
        self.setup = setup
        self.seats = seats
        self.tones = tones
        self.currentCrossover = currentCrossover
    }
}
