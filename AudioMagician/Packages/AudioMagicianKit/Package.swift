// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral engine for Audio Magician. Nothing in here touches UIKit,
// SwiftUI or AVFoundation, so every target builds and tests on macOS CI.
let package = Package(
    name: "AudioMagicianKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SignalKit", targets: ["SignalKit"]),
        .library(name: "Calibration", targets: ["Calibration"]),
        .library(name: "ReceiverKit", targets: ["ReceiverKit"]),
        .library(name: "RoomAnalysis", targets: ["RoomAnalysis"]),
        .library(name: "Recommendations", targets: ["Recommendations"]),
    ],
    targets: [
        .target(name: "SignalKit"),
        .target(name: "Calibration", dependencies: ["SignalKit"], resources: [.process("Resources")]),
        .target(name: "ReceiverKit", resources: [.process("Resources")]),
        .target(name: "RoomAnalysis", dependencies: ["SignalKit", "Calibration", "ReceiverKit"]),
        .target(name: "Recommendations", dependencies: ["SignalKit", "RoomAnalysis", "ReceiverKit"]),
        .testTarget(name: "SignalKitTests", dependencies: ["SignalKit"]),
        .testTarget(name: "ReceiverKitTests", dependencies: ["ReceiverKit", "Calibration"]),
        .testTarget(name: "RoomAnalysisTests", dependencies: ["RoomAnalysis", "SignalKit"]),
        .testTarget(name: "RecommendationsTests", dependencies: ["Recommendations", "RoomAnalysis", "ReceiverKit", "SignalKit"]),
    ]
)
