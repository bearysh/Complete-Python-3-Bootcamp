import AVFoundation
import Observation

/// Owns the audio session policy: play-and-record, measurement mode, Bluetooth
/// A2DP output only (never HFP, which would take over the mic), built-in mic
/// pinned to one data source so the calibration curve stays valid.
@MainActor
@Observable
final class AudioSessionController {
    struct RouteStatus: Equatable {
        var outputName: String = "—"
        var outputIsA2DP = false
        var outputIsHFP = false
        var inputIsBuiltInMic = false
        var inputDataSource: String?
        var sampleRate: Double = 0
        var outputLatency: Double = 0

        /// Ready to measure: receiver over A2DP, phone mic in.
        var isReady: Bool { outputIsA2DP && inputIsBuiltInMic && !outputIsHFP }
    }

    private(set) var route = RouteStatus()
    private(set) var lastError: String?
    /// Which built-in mic the calibration assumes.
    var preferredMicOrientation: AVAudioSession.Orientation = .bottom

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRoute() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.activate() }
        })
    }

    /// Configures and activates the session. Safe to call repeatedly.
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // .allowBluetoothA2DP only: no .allowBluetoothHFP, so iOS never switches to the headset profile.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            try pinBuiltInMic()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        refreshRoute()
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func pinBuiltInMic() throws {
        let session = AVAudioSession.sharedInstance()
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try session.setPreferredInput(mic)
        if let source = mic.dataSources?.first(where: { $0.orientation == preferredMicOrientation }) {
            if source.supportedPolarPatterns?.contains(.omnidirectional) == true {
                try source.setPreferredPolarPattern(.omnidirectional)
            }
            try mic.setPreferredDataSource(source)
        }
    }

    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let r = session.currentRoute
        var s = RouteStatus()
        if let out = r.outputs.first {
            s.outputName = out.portName
            s.outputIsA2DP = out.portType == .bluetoothA2DP
            s.outputIsHFP = out.portType == .bluetoothHFP
        }
        if let input = r.inputs.first {
            s.inputIsBuiltInMic = input.portType == .builtInMic
            s.inputDataSource = input.selectedDataSource?.dataSourceName
        }
        s.sampleRate = session.sampleRate
        s.outputLatency = session.outputLatency
        route = s
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
}
