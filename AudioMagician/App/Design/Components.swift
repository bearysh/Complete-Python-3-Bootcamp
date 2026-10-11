import SwiftUI

/// Big, glowing capsule button used for the one primary action on each screen.
struct PrimaryButton: View {
    var title: String
    var systemImage: String?
    var tint: Color = Theme.lumen
    var isEnabled = true
    var action: () -> Void

    @State private var tapped = 0

    var body: some View {
        Button {
            tapped += 1
            action()
        } label: {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                Capsule().fill(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: tint.opacity(isEnabled ? 0.45 : 0), radius: 18, y: 6)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
    }
}

struct SecondaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.mist)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Frosted card on the aura.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Standard screen layout: aura, title block, scrolling content, pinned actions.
struct StepScaffold<Content: View, Actions: View>: View {
    var mood: Theme.Mood = .calm
    var eyebrow: String?
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ZStack {
            AuraBackground(mood: mood)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let eyebrow {
                                Text(eyebrow.uppercased())
                                    .font(.caption2Rounded)
                                    .tracking(1.6)
                                    .foregroundStyle(mood.accent)
                            }
                            Text(title)
                                .font(.display(30))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.bodySoft)
                                    .foregroundStyle(Theme.mist)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                VStack(spacing: 6) { actions }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension StepScaffold where Actions == EmptyView {
    init(mood: Theme.Mood = .calm, eyebrow: String? = nil, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(mood: mood, eyebrow: eyebrow, title: title, subtitle: subtitle, content: content, actions: { EmptyView() })
    }
}

/// Row with an icon bubble, used in checklists and "what you need".
struct IconRow: View {
    var systemImage: String
    var title: String
    var detail: String?
    var tint: Color = Theme.lumen
    var done = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: done ? "checkmark" : systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Ring gauge with a highlighted target zone ("just right").
struct TargetRing: View {
    /// 0…1 position of the needle.
    var value: Double
    var target: ClosedRange<Double>
    var lineWidth: CGFloat = 14

    var inTarget: Bool { target.contains(value) }

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: target.lowerBound * 0.75, to: target.upperBound * 0.75)
                .stroke(Theme.aurora.opacity(0.35), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: max(0.001, min(1, value)) * 0.75)
                .stroke(inTarget ? Theme.aurora : Theme.lumen, style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: (inTarget ? Theme.aurora : Theme.lumen).opacity(0.6), radius: 8)
        }
        .animation(.spring(duration: 0.4), value: value)
    }
}

/// Animated score ring for the results headline.
struct ScoreRing: View {
    var score: Int
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 12)
            Circle().trim(from: 0, to: shown / 100)
                .stroke(AngularGradient(colors: [Theme.orchid, Theme.aurora, Theme.lumen, Theme.orchid], center: .center),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(shown))")
                    .font(.display(44))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: shown))
                Text("room score").font(.caption2Rounded).foregroundStyle(Theme.mist)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).delay(0.2)) { shown = Double(score) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Room score \(score) out of 100")
    }
}

struct Pill: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption2Rounded)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Top-down room drawing with the user's speakers and (optionally) seats.
struct RoomDiagram: View {
    var channels: [SpeakerChannelDisplay]
    var seats: [SeatDot] = []
    var highlight: String?

    struct SpeakerChannelDisplay: Identifiable {
        var id: String
        var label: String
        var x: Double
        var y: Double
        var active: Bool
    }

    struct SeatDot: Identifiable {
        var id: Int
        var x: Double
        var done: Bool
        var current: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white.opacity(0.03)))
                // Sofa
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07))
                    .frame(width: w * 0.5, height: h * 0.1)
                    .position(x: w * 0.5, y: h * 0.72)
                ForEach(seats) { s in
                    Circle()
                        .fill(s.done ? Theme.aurora : (s.current ? Theme.lumen : Color.white.opacity(0.25)))
                        .frame(width: s.current ? 16 : 12, height: s.current ? 16 : 12)
                        .shadow(color: s.current ? Theme.lumen : .clear, radius: 8)
                        .position(x: w * s.x, y: h * 0.7)
                }
                ForEach(channels) { c in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(c.id == highlight ? Theme.lumen : (c.active ? Theme.orchid.opacity(0.9) : Color.white.opacity(0.18)))
                            .frame(width: 18, height: 18)
                            .shadow(color: c.id == highlight ? Theme.lumen : .clear, radius: 10)
                        Text(c.label).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(Theme.mist)
                    }
                    .position(x: w * c.x, y: h * c.y + 10)
                }
            }
        }
        .animation(.spring(duration: 0.4), value: highlight)
    }
}
