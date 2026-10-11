import Foundation

enum DeviceInfo {
    /// Hardware model identifier, e.g. "iPhone18,2". On the simulator, the simulated model.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != nil
    }
}
