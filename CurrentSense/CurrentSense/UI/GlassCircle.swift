import SwiftUI
import CurrentSenseCore

/// Layered glass disc: material, tinted diffusion, inner depth, caustic, specular highlight, rim light.
/// Animation follows the quantised validated level, never raw sensor samples.
struct GlassCircle: View {
    let phase: MeasurementPhase
    let level: Double
    let progress: Double
    let title: String
    let subtitle: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var quantizedLevel: Double { (level * 20).rounded() / 20 }

    private var scale: CGFloat {
        switch phase {
        case .idle, .stopped: return 0.72
        case .acquiring: return 0.86
        case .measuring: return 1.0
        }
    }

    var body: some View {
        let phaseAnimation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.78)
        let levelAnimation: Animation? = reduceMotion ? nil : .smooth(duration: 0.45)
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let tint = Palette.tint(level: quantizedLevel)
            ZStack {
                glass(side: side, tint: tint)
                if phase == .acquiring {
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: max(2, side * 0.012), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(side * 0.035)
                        .animation(.linear(duration: 0.1), value: progress)
                }
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .padding(side * 0.18)
            }
            .frame(width: side, height: side)
            .scaleEffect(scale * (breathing ? 1.02 : 1.0))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .animation(phaseAnimation, value: phase)
            .animation(levelAnimation, value: quantizedLevel)
        }
        .onAppear { updateBreathing(phase) }
        .onChange(of: phase) { _, p in updateBreathing(p) }
        .accessibilityHidden(true)   // the enclosing Button carries the accessibility description
    }

    private func updateBreathing(_ p: MeasurementPhase) {
        if p == .acquiring && !reduceMotion {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
        } else {
            withAnimation(.easeOut(duration: 0.25)) { breathing = false }
        }
    }

    private func clipped<Content: View>(_ side: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content() }.frame(width: side, height: side).clipShape(Circle())
    }

    private func glass(side: CGFloat, tint: Color) -> some View {
        let dark = scheme == .dark
        return ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(RadialGradient(colors: [tint.opacity(dark ? 0.55 : 0.45), tint.opacity(0.12)],
                                         center: UnitPoint(x: 0.35, y: 0.30), startRadius: 0, endRadius: side * 0.75))
            clipped(side) {   // inner depth
                Circle().stroke(Color.black.opacity(dark ? 0.45 : 0.22), lineWidth: side * 0.09)
                    .blur(radius: side * 0.04)
            }
            clipped(side) {   // caustic
                Ellipse().fill(tint.opacity(0.35)).frame(width: side * 0.6, height: side * 0.22)
                    .blur(radius: side * 0.05).offset(y: side * 0.3)
            }
            clipped(side) {   // specular highlight
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .frame(width: side * 0.62, height: side * 0.3).offset(y: -side * 0.3)
            }
            Circle().strokeBorder(AngularGradient(colors: [.white.opacity(0.9), .white.opacity(0.08), tint.opacity(0.55),
                                                           .white.opacity(0.08), .white.opacity(0.9)], center: .center),
                                  lineWidth: max(1.5, side * 0.006))
        }
        .compositingGroup()
        .shadow(color: tint.opacity(dark ? 0.45 : 0.30), radius: side * 0.09, y: side * 0.05)
    }
}
