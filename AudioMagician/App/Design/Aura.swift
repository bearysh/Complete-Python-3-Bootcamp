import SwiftUI

/// Slowly drifting mesh gradient behind every screen. The mood crossfades as
/// the flow moves from calm setup to measuring to success.
struct AuraBackground: View {
    var mood: Theme.Mood = .calm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let c = mood.colors
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.5 + 0.18 * sin(t * 0.21)), Float(0.5 + 0.14 * cos(t * 0.17))], [1, 0.5],
                    [0, 1], [Float(0.5 + 0.12 * cos(t * 0.13)), 1], [1, 1],
                ],
                colors: [
                    c[0], c[1], c[0],
                    c[2], c[3], c[1],
                    c[0], c[2], c[0],
                ]
            )
        }
        .animation(.easeInOut(duration: 1.6), value: mood.colors.description)
        .ignoresSafeArea()
    }
}

/// The signature visual: a soft, breathing orb of light that reacts to sound.
///
/// - `level` 0…1 swells it; `mood` tints it; `pulse` adds a gentle heartbeat
///   while a sweep is playing.
struct SoundOrb: View {
    var level: Double = 0
    var mood: Theme.Mood = .calm
    var pulse = false
    var size: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let base = min(canvasSize.width, canvasSize.height) / 2 * 0.62
                let breathe = reduceMotion ? 0 : 0.04 * sin(t * 0.9)
                let beat = pulse && !reduceMotion ? 0.05 * pow(max(0, sin(t * 3.2)), 8) : 0
                let swell = 1 + breathe + beat + 0.35 * min(max(level, 0), 1)
                let accent = mood.accent

                // Outer halo
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: base * 0.35))
                    let r = base * swell * 1.25
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(accent.opacity(0.35)))
                }
                // Three drifting lobes give it a living, liquid edge.
                for i in 0..<3 {
                    let phase = Double(i) * 2.094
                    let wobble = reduceMotion ? 0 : base * 0.09
                    let dx = wobble * cos(t * (0.5 + 0.13 * Double(i)) + phase)
                    let dy = wobble * sin(t * (0.43 + 0.11 * Double(i)) + phase)
                    let r = base * swell * (0.82 + 0.06 * Double(i))
                    let colors: [Color] = [i == 0 ? .white.opacity(0.9) : accent.opacity(0.95), accent.opacity(0.55), Theme.orchid.opacity(0.0)]
                    ctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: base * 0.12))
                        layer.fill(
                            Path(ellipseIn: CGRect(x: center.x + dx - r, y: center.y + dy - r, width: 2 * r, height: 2 * r)),
                            with: .radialGradient(Gradient(colors: colors), center: CGPoint(x: center.x + dx - r * 0.25, y: center.y + dy - r * 0.3), startRadius: 0, endRadius: r * 1.1)
                        )
                    }
                }
                // Bright core
                let core = base * 0.28 * swell
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: core * 0.6))
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: 2 * core, height: 2 * core)), with: .color(.white.opacity(0.75)))
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.35), value: level)
        .accessibilityHidden(true)
    }
}

/// Concentric ripples that expand outward, used while sound is playing.
struct Ripples: View {
    var active: Bool
    var color: Color = Theme.orchid

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                guard active else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                for i in 0..<4 {
                    let p = (t * 0.35 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                    let r = maxR * (0.35 + 0.65 * p)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(color.opacity(0.45 * (1 - p))), lineWidth: 1.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
