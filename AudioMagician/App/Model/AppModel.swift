import Foundation
import Observation
import Calibration
import ReceiverKit

/// App-wide state: onboarding, receiver profiles, microphone capability, unlock.
@MainActor
@Observable
final class AppModel {
    var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "hasOnboarded") }
    }

    /// Developer builds can pretend the mic is calibrated (flat curve) to
    /// exercise the full sweep flow before real curves exist.
    var developerFullMode: Bool {
        didSet { UserDefaults.standard.set(developerFullMode, forKey: "developerFullMode") }
    }

    let profiles: [ReceiverProfile] = ProfileLibrary.bundled()
    let calibrations = CalibrationLibrary.bundled()
    let audio = AudioSessionController()
    let unlock = UnlockStore()
    let deviceModel = DeviceInfo.modelIdentifier

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        #if DEBUG
        developerFullMode = UserDefaults.standard.bool(forKey: "developerFullMode")
        #else
        developerFullMode = false
        #endif
    }

    var capability: MeasurementCapability {
        if let cal = calibrations.calibration(forDevice: deviceModel) { return .full(cal) }
        #if DEBUG
        if developerFullMode { return .full(CalibrationLibrary.developerFlat(device: deviceModel)) }
        #endif
        return .levelsOnly
    }

    var defaultProfile: ReceiverProfile? { profiles.first }

    func profile(id: String) -> ReceiverProfile? { profiles.first { $0.id == id } }
}
