import Foundation
import SwiftData
import RoomAnalysis
import Recommendations

/// A saved room. Setup and results are stored as JSON blobs of the engine's
/// Codable types so the schema stays stable while the engine evolves.
@Model
final class Room {
    var name: String
    var createdAt: Date
    var setupData: Data
    @Relationship(deleteRule: .cascade, inverse: \TuningRecord.room) var tunings: [TuningRecord] = []

    init(name: String, setup: RoomSetup) {
        self.name = name
        createdAt = .now
        setupData = (try? JSONEncoder().encode(setup)) ?? Data()
    }

    var setup: RoomSetup? { try? JSONDecoder().decode(RoomSetup.self, from: setupData) }

    var latest: TuningRecord? { tunings.max { $0.date < $1.date } }
}

@Model
final class TuningRecord {
    var date: Date
    var score: Int
    var calibrated: Bool
    var sessionData: Data
    var analysisData: Data
    var planData: Data
    var room: Room?

    init(session: SessionData, analysis: AnalysisResult, plan: TuningPlan) {
        date = .now
        score = analysis.score
        calibrated = analysis.calibrated
        let enc = JSONEncoder()
        sessionData = (try? enc.encode(session)) ?? Data()
        analysisData = (try? enc.encode(analysis)) ?? Data()
        planData = (try? enc.encode(plan)) ?? Data()
    }

    var session: SessionData? { try? JSONDecoder().decode(SessionData.self, from: sessionData) }
    var analysis: AnalysisResult? { try? JSONDecoder().decode(AnalysisResult.self, from: analysisData) }
    var plan: TuningPlan? { try? JSONDecoder().decode(TuningPlan.self, from: planData) }
}
