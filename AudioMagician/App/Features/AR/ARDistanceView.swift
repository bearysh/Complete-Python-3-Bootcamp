import SwiftUI
import ARKit
import SceneKit
import ReceiverKit

/// Stand at your seat, aim the crosshair at a speaker, tap Capture.
/// Uses LiDAR scene depth where available (iPhone Pro models), otherwise a raycast.
struct ARDistanceView: View {
    let channel: SpeakerChannel
    var done: (Double?) -> Void

    @State private var distance: Double?
    @State private var captured: Double?
    @State private var unsupported = !ARWorldTrackingConfiguration.isSupported

    var body: some View {
        ZStack {
            if unsupported {
                AuraBackground()
                Text("This device can't measure with the camera. Please use a tape measure.")
                    .multilineTextAlignment(.center).foregroundStyle(.white).padding(32)
            } else {
                ARDistanceContainer(distance: $distance).ignoresSafeArea()
                Crosshair(active: distance != nil)
            }
            VStack {
                HStack {
                    Button { done(nil) } label: {
                        Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .tint(.white)
                    .accessibilityLabel("Cancel")
                    Spacer()
                }
                .padding()
                VStack(spacing: 6) {
                    Text("Aim at your \(channel.displayName.lowercased())").font(.headlineRounded).foregroundStyle(.white)
                    Text("Stand where you sit, phone at head height.").font(.subheadline).foregroundStyle(Theme.mist)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                Spacer()
                Text(distance.map { String(format: "%.2f m · %.1f ft", $0, $0 / 0.3048) } ?? "Finding the speaker…")
                    .font(.display(28)).foregroundStyle(.white).monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.bottom, 8)
                PrimaryButton(title: "Capture", systemImage: "scope", isEnabled: distance != nil) {
                    captured = distance
                    done(distance)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct Crosshair: View {
    var active: Bool

    var body: some View {
        ZStack {
            Circle().stroke(active ? Theme.aurora : .white.opacity(0.6), lineWidth: 2).frame(width: 54, height: 54)
            Circle().fill(active ? Theme.aurora : .white).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.4), radius: 4)
        .animation(.spring, value: active)
        .accessibilityHidden(true)
    }
}

struct ARDistanceContainer: UIViewRepresentable {
    @Binding var distance: Double?

    func makeCoordinator() -> Coordinator { Coordinator(distance: $distance) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        view.session.delegate = context.coordinator
        context.coordinator.view = view
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.planeDetection = [.horizontal, .vertical]
        view.session.run(config)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        var distance: Binding<Double?>
        weak var view: ARSCNView?
        private var recent: [Double] = []
        private var lastUpdate = Date.distantPast

        init(distance: Binding<Double?>) {
            self.distance = distance
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard Date().timeIntervalSince(lastUpdate) > 0.1 else { return }
            lastUpdate = Date()
            let d = Self.centerDepth(frame) ?? raycastDistance(frame)
            guard let d, d > 0.2, d < 12 else { return }
            recent.append(d)
            if recent.count > 9 { recent.removeFirst() }
            let median = recent.sorted()[recent.count / 2]
            DispatchQueue.main.async { self.distance.wrappedValue = median }
        }

        /// LiDAR depth at the centre of the frame, metres.
        static func centerDepth(_ frame: ARFrame) -> Double? {
            guard let map = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return nil }
            CVPixelBufferLockBaseAddress(map, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
            let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
            let row = CVPixelBufferGetBytesPerRow(map)
            // Average a small patch for stability.
            var sum: Float = 0
            var n: Float = 0
            for dy in -2...2 {
                let p = base.advanced(by: (h / 2 + dy) * row).assumingMemoryBound(to: Float32.self)
                for dx in -2...2 {
                    let v = p[w / 2 + dx]
                    if v.isFinite && v > 0 { sum += v; n += 1 }
                }
            }
            return n > 0 ? Double(sum / n) : nil
        }

        private func raycastDistance(_ frame: ARFrame) -> Double? {
            guard let view else { return nil }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard let query = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
                  let hit = view.session.raycast(query).first else { return nil }
            let cam = frame.camera.transform.columns.3
            let p = hit.worldTransform.columns.3
            let d = simd_distance(SIMD3(cam.x, cam.y, cam.z), SIMD3(p.x, p.y, p.z))
            return Double(d)
        }
    }
}
