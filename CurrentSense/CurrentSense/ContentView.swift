import SwiftUI
import Charts
import UIKit

private enum MeasurementMode: String, CaseIterable, Identifiable {
    case ac = "AC"
    case dc = "DC"
    var id: String { rawValue }
}

private enum FieldPalette {
    static let background = LinearGradient(
        colors: [Color(red: 0.018, green: 0.035, blue: 0.075),
                 Color(red: 0.035, green: 0.055, blue: 0.12),
                 Color(red: 0.012, green: 0.02, blue: 0.05)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // Simulation-style heat map: low field = blue, high field = red.
    static func color(for magnitude: Double) -> Color {
        let t = min(max(magnitude / 250.0, 0), 1)
        let stops: [(Double, Color)] = [
            (0.00, Color(red: 0.02, green: 0.16, blue: 0.95)),
            (0.20, Color(red: 0.0, green: 0.72, blue: 1.0)),
            (0.40, Color(red: 0.05, green: 0.92, blue: 0.55)),
            (0.60, Color(red: 1.0, green: 0.90, blue: 0.05)),
            (0.80, Color(red: 1.0, green: 0.38, blue: 0.04)),
            (1.00, Color(red: 1.0, green: 0.04, blue: 0.12))
        ]
        for index in 0..<(stops.count - 1) {
            let (a, ca) = stops[index]
            let (b, cb) = stops[index + 1]
            if t >= a && t <= b {
                let u = (t - a) / (b - a)
                return Color(
                    red: ca.components.red + (cb.components.red - ca.components.red) * u,
                    green: ca.components.green + (cb.components.green - ca.components.green) * u,
                    blue: ca.components.blue + (cb.components.blue - ca.components.blue) * u
                )
            }
        }
        return stops.last!.1
    }
}

private extension Color {
    var components: (red: Double, green: Double, blue: Double) {
        let ui = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }
}

struct ContentView: View {
    @StateObject private var sensor = MagnetometerService()
    @State private var mode: MeasurementMode = .ac
    @State private var showShareSheet = false
    @State private var exportURL: URL?

    private var fieldMagnitude: Double? { sensor.latestSample?.magnitude }
    private var fieldColor: Color { FieldPalette.color(for: fieldMagnitude ?? 0) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                FieldPalette.background.ignoresSafeArea()
                ambientGlow
                VStack(spacing: 0) {
                    topControls
                        .padding(.top, 8)

                    modePicker
                        .padding(.top, 24)
                        .padding(.horizontal, 34)

                    Spacer(minLength: 12)

                    FieldOrb(isMeasuring: sensor.isRunning,
                             magnitude: fieldMagnitude ?? 0,
                             tint: fieldColor)
                        .frame(width: min(geometry.size.width * 0.86, geometry.size.height * 0.48),
                               height: min(geometry.size.width * 0.86, geometry.size.height * 0.48))
                        .contentShape(Circle())
                        .onTapGesture { toggleMeasurement() }
                        .accessibilityElement()
                        .accessibilityLabel(sensor.isRunning ? "Stop measurement" : "Start measurement")
                        .accessibilityHint("Tap the glass sphere to start or stop measuring.")
                        .accessibilityAddTraits(.isButton)
                        .padding(.top, 4)

                    VStack(spacing: 8) {
                        Text(sensor.isRunning ? "Tap the circle to stop measuring" : "Tap the circle to start measuring")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))
                            .contentTransition(.opacity)
                        Text("Place the back of your iPhone near the insulated cable")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                        if let error = sensor.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                        if sensor.isRunning {
                            HStack(spacing: 6) {
                                Circle().fill(fieldColor).frame(width: 6, height: 6)
                                Text("LIVE FIELD")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .tracking(1.6)
                                    .foregroundStyle(fieldColor)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)

                    Spacer(minLength: 16)

                    measurementBar
                        .padding(.horizontal, 18)
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom == 0 ? 14 : 8, 8))
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: sensor.isRunning)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.45, dampingFraction: 0.76), value: fieldMagnitude)
        .sheet(isPresented: $showShareSheet) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .onDisappear { sensor.stop() }
    }

    private var ambientGlow: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(fieldColor.opacity(sensor.isRunning ? 0.17 : 0.08))
                    .frame(width: proxy.size.width * 0.95)
                    .blur(radius: 100)
                    .offset(x: -proxy.size.width * 0.25, y: -proxy.size.height * 0.08)
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: proxy.size.width * 0.7)
                    .blur(radius: 90)
                    .offset(x: proxy.size.width * 0.35, y: proxy.size.height * 0.3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: fieldColor)
    }

    private var topControls: some View {
        HStack {
            Spacer()
            Button {
                guard let url = sensor.exportCSV() else { return }
                exportURL = url
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
            }
            .disabled(sensor.samples.isEmpty)
            .accessibilityLabel("Export measurements as CSV")
        }
        .padding(.horizontal, 20)
    }

    private var modePicker: some View {
        HStack(spacing: 5) {
            ForEach(MeasurementMode.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                        mode = item
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item == .ac ? "waveform" : "arrow.right")
                            .font(.system(size: 17, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(mode == item ? .white : .white.opacity(0.55))
                    .background {
                        if mode == item {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [fieldColor.opacity(0.62), fieldColor.opacity(0.22)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.28)))
                                .shadow(color: fieldColor.opacity(0.22), radius: 12, y: 3)
                        }
                    }
                }
                .buttonStyle(OrbPressStyle())
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private var measurementBar: some View {
        HStack(spacing: 0) {
            metricColumn(title: "CURRENT", value: "—", unit: "A",
                         detail: mode == .ac ? "AC • 50 Hz" : "DC",
                         tint: fieldColor)
            separator
            metricColumn(title: "MAGNETIC FIELD",
                         value: fieldMagnitude.map { String(format: "%.1f", $0) } ?? "—",
                         unit: "µT",
                         detail: sensor.isRunning ? "Live reading" : "Tap sphere to begin",
                         tint: fieldColor)
            separator
            metricColumn(title: "DISTANCE", value: "—", unit: "cm",
                         detail: "Not measured",
                         tint: .white.opacity(0.65))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.015)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .shadow(color: fieldColor.opacity(0.12), radius: 22, y: 8)
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 54)
    }

    private func metricColumn(title: String, value: String, unit: String,
                              detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
            }
            Text(detail)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func toggleMeasurement() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            if sensor.isRunning {
                sensor.stop()
            } else {
                sensor.start()
            }
        }
    }
}

private struct FieldOrb: View {
    let isMeasuring: Bool
    let magnitude: Double
    let tint: Color
    @State private var pulse = false

    private var intensity: Double { min(max(magnitude / 250.0, 0.0), 1.0) }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.28), tint.opacity(0.06), .clear],
                                         center: .center, startRadius: side * 0.08, endRadius: side * 0.62))
                    .scaleEffect(isMeasuring ? (pulse ? 1.06 + intensity * 0.05 : 0.98) : 1)
                    .blur(radius: 8)

                Circle()
                    .fill(RadialGradient(stops: [
                        .init(color: tint.opacity(0.82), location: 0),
                        .init(color: tint.opacity(0.55), location: 0.25),
                        .init(color: Color.blue.opacity(0.30), location: 0.58),
                        .init(color: Color(red: 0.08, green: 0.04, blue: 0.22).opacity(0.68), location: 0.82),
                        .init(color: tint.opacity(0.32), location: 1)
                    ], center: .init(x: pulse ? 0.42 : 0.58, y: pulse ? 0.44 : 0.56),
                       startRadius: side * 0.015, endRadius: side * 0.70))
                    .overlay {
                        Circle().stroke(LinearGradient(colors: [.white.opacity(0.9), tint.opacity(0.8), .white.opacity(0.22)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                    }
                    .overlay {
                        Circle().stroke(tint.opacity(0.6), lineWidth: 5).blur(radius: 7)
                    }
                    .overlay {
                        Circle().fill(LinearGradient(colors: [.white.opacity(0.24), .clear, tint.opacity(0.15)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            .mask(Circle().stroke(lineWidth: side * 0.055))
                    }
                    .shadow(color: tint.opacity(0.28 + intensity * 0.28), radius: 25 + CGFloat(intensity) * 20, y: 8)
                    .scaleEffect(isMeasuring ? (pulse ? 1.0 + intensity * 0.025 : 0.975) : 1)
                    .rotationEffect(.degrees(isMeasuring ? (pulse ? 3.5 : -3.5) : 0))

                // Concentric field contours echo scientific simulation plots.
                ForEach(0..<7, id: \.self) { index in
                    Circle()
                        .stroke(tint.opacity(0.18 + intensity * 0.25), lineWidth: index == 0 ? 1.8 : 0.8)
                        .frame(width: side * (0.16 + CGFloat(index) * 0.115),
                               height: side * (0.16 + CGFloat(index) * 0.115))
                        .blur(radius: index > 4 ? 0.6 : 0)
                        .rotationEffect(.degrees(isMeasuring ? (pulse ? 9 : -9) : 0))
                }

                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), tint, tint.opacity(0.05)],
                                         center: .center, startRadius: 0, endRadius: side * 0.09))
                    .frame(width: side * (0.035 + CGFloat(intensity) * 0.025),
                           height: side * (0.035 + CGFloat(intensity) * 0.025))
                    .shadow(color: tint, radius: 16 + CGFloat(intensity) * 18)

                if !isMeasuring {
                    Image(systemName: "play.fill")
                        .font(.system(size: side * 0.065, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 5)
                        .offset(y: side * 0.34)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .onAppear {
                withAnimation(.easeInOut(duration: isMeasuring ? 1.7 : 3.0).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: isMeasuring) { _, active in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    pulse = active
                }
                if active {
                    withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.76), value: intensity)
        }
    }
}

private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
