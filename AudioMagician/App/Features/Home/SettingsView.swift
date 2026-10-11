import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("Microphone") {
                    LabeledContent("iPhone model", value: model.deviceModel)
                    LabeledContent("Mode", value: model.capability.isCalibrated ? "Full measurement" : "Levels & distances")
                    if let cal = model.capability.calibration {
                        LabeledContent("Calibration", value: cal.displayName)
                    }
                }
                Section("Unlock") {
                    LabeledContent("Status", value: model.unlock.isUnlocked ? "Unlocked" : "Not unlocked")
                    Button("Restore purchase") { Task { await model.unlock.restore() } }
                }
                Section("Advanced") {
                    NavigationLink("Measurement lab") { LabView() }
                }
                #if DEBUG
                Section("Developer") {
                    Toggle("Pretend mic is calibrated (flat curve)", isOn: $model.developerFullMode)
                    Toggle("Unlock without purchase", isOn: Binding(get: { model.unlock.debugUnlocked }, set: { model.unlock.debugUnlocked = $0 }))
                    Button("Show onboarding again") { model.hasOnboarded = false; dismiss() }
                }
                #endif
                Section {
                    Text("Audio Magician measures on your device. Nothing you record leaves your iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuraBackground())
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
