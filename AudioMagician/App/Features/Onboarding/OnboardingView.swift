import SwiftUI

/// Welcome → what you'll need → microphone permission.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var askingMic = false
    @State private var micDenied = false

    var body: some View {
        ZStack {
            AuraBackground(mood: page == 2 ? .listening : .calm)
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    needs.tag(1)
                    microphone.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == page ? Theme.lumen : Color.white.opacity(0.2))
                            .frame(width: i == page ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(duration: 0.35), value: page)
                .padding(.bottom, 18)

                Group {
                    switch page {
                    case 0: PrimaryButton(title: "Let's begin") { page = 1 }
                    case 1: PrimaryButton(title: "I'm ready") { page = 2 }
                    default:
                        PrimaryButton(title: micDenied ? "Open Settings" : "Allow microphone", systemImage: "mic.fill", tint: Theme.aurora, isEnabled: !askingMic) {
                            if micDenied {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            } else {
                                Task { await requestMic() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()
            SoundOrb(level: 0.1, mood: .calm, size: 240)
            VStack(spacing: 12) {
                Text("Audio Magician")
                    .font(.display(38))
                    .foregroundStyle(.white)
                Text("Your room, tuned.\nWe'll listen, explain what we hear, and show you exactly what to change.")
                    .font(.bodySoft)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.mist)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var needs: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("What you'll need")
                .font(.display(30))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 18) {
                IconRow(systemImage: "clock", title: "About 15 minutes", detail: "Most of it is just sitting still while we listen.")
                IconRow(systemImage: "speaker.wave.2", title: "Your receiver and its remote", detail: "We'll guide you through every menu.", tint: Theme.orchid)
                IconRow(systemImage: "moon.zzz", title: "A quiet room", detail: "Pause the dishwasher and fans if you can.", tint: Theme.aurora)
                IconRow(systemImage: "ruler", title: "A tape measure (optional)", detail: "Or use your camera to measure speaker distances.", tint: Theme.mist)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var microphone: some View {
        VStack(spacing: 26) {
            Spacer()
            SoundOrb(level: 0.3, mood: .listening, size: 200)
            VStack(spacing: 12) {
                Text("We listen with your iPhone")
                    .font(.display(28))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(micDenied
                     ? "Microphone access is off. Turn it on in Settings so we can hear your speakers."
                     : "Your iPhone's microphone hears your speakers the way you do. Sound is analysed on your phone and never leaves it.")
                    .font(.bodySoft)
                    .foregroundStyle(Theme.mist)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func requestMic() async {
        askingMic = true
        let ok = await AudioSessionController.requestMicrophoneAccess()
        askingMic = false
        if ok {
            model.hasOnboarded = true
        } else {
            micDenied = true
        }
    }
}
