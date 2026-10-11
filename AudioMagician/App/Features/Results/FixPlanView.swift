import SwiftUI
import ReceiverKit
import Recommendations

/// The step-by-step plan. Advice is free; exact receiver settings need the unlock.
struct FixPlanView: View {
    @Environment(TuningFlow.self) private var flow
    @Environment(AppModel.self) private var model
    @State private var done: Set<String> = []
    @State private var expanded: String?

    var body: some View {
        let unlocked = model.unlock.isUnlocked
        StepScaffold(mood: .calm, eyebrow: "Your fix plan", title: titleText,
                     subtitle: unlocked ? "Work through these in order with your remote. Tick each one off as you go." : "Here's what we'll change. Unlock to see the exact settings for your \(flow.profile.model).") {
            if let plan = flow.plan {
                if !unlocked && !plan.settingSteps.isEmpty {
                    UnlockCard()
                }
                ForEach(groups(plan)) { section in
                    let group = section.group, steps = section.steps
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title.uppercased()).font(.caption2Rounded).tracking(1.4).foregroundStyle(Theme.mist)
                        ForEach(steps) { step in
                            PlanStepCard(step: step, locked: step.requiresUnlock && !unlocked, isDone: done.contains(step.id), expanded: expanded == step.id) {
                                withAnimation(.spring(duration: 0.35)) { expanded = expanded == step.id ? nil : step.id }
                            } toggleDone: {
                                withAnimation(.spring(duration: 0.35)) {
                                    if done.contains(step.id) { done.remove(step.id) } else { done.insert(step.id) }
                                }
                            }
                        }
                    }
                }
                if !plan.limitations.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Coming in an update").font(.headlineRounded).foregroundStyle(.white)
                            ForEach(plan.limitations, id: \.self) { l in
                                Label(l, systemImage: "clock.arrow.circlepath").font(.subheadline).foregroundStyle(Theme.mist)
                            }
                        }
                    }
                }
                if !flow.profile.verified {
                    Text("Menu names are based on Onkyo's usual layout and may differ slightly on your receiver.")
                        .font(.footnote).foregroundStyle(Theme.mist)
                }
            }
        } actions: {
            if !flow.isReview {
                PrimaryButton(title: "I've made the changes", systemImage: "checkmark.circle", tint: Theme.aurora) { flow.go(.verify) }
            }
        }
    }

    private var titleText: String {
        guard let plan = flow.plan else { return "Your plan" }
        let n = plan.steps.count
        return n == 0 ? "Nothing to change" : "\(n) \(n == 1 ? "step" : "steps") to better sound"
    }

    struct Section: Identifiable {
        var group: PlanStep.Group
        var steps: [PlanStep]
        var id: PlanStep.Group { group }
    }

    private func groups(_ plan: TuningPlan) -> [Section] {
        PlanStep.Group.allCases.compactMap { g in
            let s = plan.steps.filter { $0.group == g }
            return s.isEmpty ? nil : Section(group: g, steps: s)
        }
    }
}

struct PlanStepCard: View {
    let step: PlanStep
    let locked: Bool
    let isDone: Bool
    let expanded: Bool
    var toggleExpanded: () -> Void
    var toggleDone: () -> Void

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: toggleDone) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isDone ? Theme.aurora : Theme.mist)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(locked)
                    .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                        if step.tryThenCheck { Text("Try it, then re-check").font(.caption).foregroundStyle(Theme.orchid) }
                    }
                    Spacer()
                    if let g = step.guide {
                        ValueBadge(text: g.valueText, locked: locked)
                    }
                }
                if let g = step.guide, !locked, let menu = g.menu {
                    MenuPathView(menu: menu).padding(.leading, 40)
                }
                if let advice = step.advice {
                    Text(advice).font(.subheadline).foregroundStyle(.white.opacity(0.9)).padding(.leading, 40)
                }
                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        Text(expanded ? "Hide why" : "Why?")
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.lumen)
                }
                .padding(.leading, 40)
                if expanded {
                    Text(step.why).font(.subheadline).foregroundStyle(Theme.mist).padding(.leading, 40)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .opacity(isDone ? 0.6 : 1)
    }
}

struct ValueBadge: View {
    let text: String
    let locked: Bool

    var body: some View {
        ZStack {
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.lumen, in: Capsule())
                .blur(radius: locked ? 6 : 0)
            if locked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.ink)
            }
        }
        .accessibilityLabel(locked ? "Locked value" : text)
    }
}

struct UnlockCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.unlock
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(Theme.lumen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unlock your exact settings").font(.headlineRounded).foregroundStyle(.white)
                        Text("One purchase. Every room, every re-tune, forever.").font(.subheadline).foregroundStyle(Theme.mist)
                    }
                }
                PrimaryButton(title: store.product.map { "Unlock for \($0.displayPrice)" } ?? "Unlock", systemImage: "lock.open", isEnabled: !store.isWorking) {
                    Task { await store.purchase() }
                }
                Button("Restore purchase") { Task { await store.restore() } }
                    .font(.footnote)
                    .tint(Theme.mist)
                    .frame(maxWidth: .infinity)
                if let e = store.lastError {
                    Text(e).font(.footnote).foregroundStyle(Theme.coral)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.lumen.opacity(0.5), lineWidth: 1))
    }
}
