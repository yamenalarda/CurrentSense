import SwiftUI
import Charts
import UIKit

private enum MeasurementMode: String, CaseIterable, Identifiable {
    case ac = "AC"
    case dc = "DC"
    var id: String { rawValue }
}

private enum FieldPalette {
    static func background(for scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.018, green: 0.035, blue: 0.075),
                    Color(red: 0.035, green: 0.055, blue: 0.12),
                    Color(red: 0.012, green: 0.02, blue: 0.05)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.99, blue: 1.00),
                Color(red: 0.90, green: 0.94, blue: 1.00),
                Color(red: 0.96, green: 0.975, blue: 1.00)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // Simulation-style heat map: low field = blue, high field = red.
    static func color(for magnitude: Double) -> Color {
        let t = min(max(magnitude / 50.0, 0), 1)
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
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var sensor = MagnetometerService()
    @State private var mode: MeasurementMode = .ac

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.94) : .black.opacity(0.86)
    }
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.62) : .black.opacity(0.62)
    }
    private var mutedTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.58) : .black.opacity(0.56)
    }

    // Only display a field-change value during an active measurement.
    // In standby, the detector is communicated solely through the small orb's appearance.
    private var fieldMagnitude: Double? {
        guard sensor.isRunning else { return nil }
        return sensor.latestSample?.deltaMagnitude
    }
    private var fieldColor: Color { FieldPalette.color(for: fieldMagnitude ?? 0) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                FieldPalette.background(for: colorScheme).ignoresSafeArea()
                ambientGlow
                VStack(spacing: 0) {
                    modePicker
                        .padding(.top, 16)
                        .padding(.horizontal, 34)

                    Spacer(minLength: 12)

                    FieldOrb(isMeasuring: sensor.isRunning,
                             magnitude: fieldMagnitude ?? 0,
                             tint: fieldColor,
                             proximitySignal: sensor.magneticSourceDetected)
                        .frame(
                            width: sensor.isRunning
                                ? min(geometry.size.width * 0.86, geometry.size.height * 0.48)
                                : min(geometry.size.width * 0.48, geometry.size.height * 0.27),
                            height: sensor.isRunning
                                ? min(geometry.size.width * 0.86, geometry.size.height * 0.48)
                                : min(geometry.size.width * 0.48, geometry.size.height * 0.27)
                        )
                        .contentShape(Circle())
                        .onTapGesture { toggleMeasurement() }
                        .accessibilityElement()
                        .accessibilityLabel(sensor.isRunning ? "Stop measurement" : "Start measurement")
                        .accessibilityHint("Tap the glass sphere to start or stop measuring.")
                        .accessibilityAddTraits(.isButton)
                        .padding(.top, 4)

                    VStack(spacing: 8) {
                        Text(
                            !sensor.isRunning
                                ? "Tap the circle to begin"
                                : (!sensor.baselineCaptured
                                    ? "Capturing baseline — keep iPhone away from cable"
                                    : "Baseline ready — move iPhone near the cable")
                        )
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        Text(
                            !sensor.isRunning
                                ? "Start away from the cable; keep the phone orientation fixed."
                                : (mode == .ac
                                    ? "Keep the phone still. AC current is not calculated."
                                    : "Keep the phone still. DC current is not calculated.")
                        )
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                        .multilineTextAlignment(.center)
                        if let error = sensor.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                        if sensor.isRunning {
                            HStack(spacing: 6) {
                                Circle().fill(sensor.baselineCaptured ? fieldColor : .yellow).frame(width: 6, height: 6)
                                Text(sensor.baselineCaptured ? "LIVE FIELD CHANGE" : "CAPTURING BASELINE")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .tracking(1.2)
                                    .foregroundStyle(sensor.baselineCaptured ? fieldColor : .yellow)
                                Text("· CAL \(sensor.calibrationQuality.uppercased())")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(sensor.calibrationQuality == "High"
                                                     ? (colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.65))
                                                     : .yellow.opacity(0.9))
                                if let rate = sensor.observedDeliveryRateHz {
                                    Text(String(format: "· %.0f Hz", rate))
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(secondaryTextColor)
                                }
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
        // No preferredColorScheme override: SwiftUI follows the device's appearance.
        .tint(colorScheme == .dark ? .white : .black)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: sensor.isRunning)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.45, dampingFraction: 0.76), value: fieldMagnitude)
        .onAppear { sensor.startMonitoring() }
        .onDisappear { sensor.stopMonitoring() }
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
                    .foregroundStyle(mode == item ? .white :
                        (colorScheme == .dark ? .white.opacity(0.55) : .black.opacity(0.58)))
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
        .overlay(Capsule().stroke(
            colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10),
            lineWidth: 1
        ))
    }

    private var measurementBar: some View {
        HStack(spacing: 0) {
            metricColumn(title: "CURRENT", value: "—", unit: "A",
                         detail: "Not calculated",
                         tint: secondaryTextColor)
            separator
            metricColumn(title: "FIELD CHANGE",
                         value: fieldMagnitude.map { String(format: "%.1f", $0) } ?? "—",
                         unit: "µT",
                         detail: !sensor.isRunning
                            ? "Start measuring"
                            : (sensor.baselineCaptured ? "Relative to baseline" : "Capturing baseline"),
                         tint: fieldColor)
            separator
            metricColumn(title: "DISTANCE", value: "—", unit: "cm",
                         detail: "Not inferable",
                         tint: secondaryTextColor)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white.opacity(0.10), .white.opacity(0.015)]
                                : [.white.opacity(0.70), .white.opacity(0.20)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(
                    colors: colorScheme == .dark
                        ? [.white.opacity(0.26), .white.opacity(0.06)]
                        : [.white.opacity(0.92), .black.opacity(0.07)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1)
        }
        .shadow(color: fieldColor.opacity(0.12), radius: 22, y: 8)
    }

    private var separator: some View {
        Rectangle()
            .fill(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.12))
            .frame(width: 1, height: 54)
    }

    private func metricColumn(title: String, value: String, unit: String,
                              detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(mutedTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
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
    let proximitySignal: Bool
    @State private var drift = false
    @State private var detectionPulse = false

    // Map measured field strength to a simulation-style spectrum:
    // blue -> cyan -> green -> yellow -> orange -> red.
    private var intensity: Double { min(max(magnitude / 50.0, 0.0), 1.0) }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let detectionTint = Color(red: 1.0, green: 0.57, blue: 0.16)
            ZStack {
                // Quiet standby feedback: only the orb changes, with no status text.
                if !isMeasuring && proximitySignal {
                    Circle()
                        .fill(RadialGradient(
                            colors: [
                                detectionTint.opacity(detectionPulse ? 0.34 : 0.12),
                                detectionTint.opacity(0.06),
                                .clear
                            ],
                            center: .center,
                            startRadius: side * 0.12,
                            endRadius: side * 0.70
                        ))
                        .frame(width: side * 1.30, height: side * 1.30)
                        .blur(radius: side * 0.04)
                        .allowsHitTesting(false)
                }

                // Soft colored bloom behind the glass disc.
                Circle()
                    .fill(RadialGradient(colors: [
                        tint.opacity(isMeasuring ? 0.42 : 0.18),
                        tint.opacity(0.10),
                        .clear
                    ], center: .center, startRadius: side * 0.12, endRadius: side * 0.62))
                    .frame(width: side * 1.12, height: side * 1.12)
                    .blur(radius: side * 0.055)
                    .scaleEffect(isMeasuring ? (drift ? 1.08 : 0.94) : 1)

                // Outer transparent glass body, with a soft rim.
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(
                            LinearGradient(colors: [
                                .white.opacity(0.26),
                                tint.opacity(0.10),
                                .white.opacity(0.025),
                                tint.opacity(0.18)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    }
                    .overlay {
                        Circle().stroke(
                            LinearGradient(colors: [
                                .white.opacity(0.92),
                                .white.opacity(0.16),
                                tint.opacity(0.68),
                                .white.opacity(0.42)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.4
                        )
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 7)
                            .blur(radius: 5)
                    }
                    .shadow(color: tint.opacity(0.24 + intensity * 0.24),
                            radius: 26 + CGFloat(intensity) * 24, y: 14)

                // Liquid, layered color inside the glass: simulation heatmap colors.
                Circle()
                    .fill(
                        AngularGradient(stops: [
                            .init(color: FieldPalette.color(for: magnitude * 0.18).opacity(0.58), location: 0.00),
                            .init(color: FieldPalette.color(for: magnitude * 0.42).opacity(0.78), location: 0.18),
                            .init(color: FieldPalette.color(for: magnitude * 0.68).opacity(0.70), location: 0.38),
                            .init(color: FieldPalette.color(for: magnitude).opacity(0.84), location: 0.60),
                            .init(color: FieldPalette.color(for: magnitude * 0.35).opacity(0.62), location: 0.82),
                            .init(color: FieldPalette.color(for: magnitude * 0.18).opacity(0.58), location: 1.00)
                        ], center: .center, startAngle: .degrees(drift ? 25 : -25),
                           endAngle: .degrees(drift ? 385 : 335))
                    )
                    .padding(side * 0.055)
                    .blur(radius: side * 0.012)
                    .mask(Circle().padding(side * 0.035))
                    .scaleEffect(isMeasuring ? (drift ? 1.025 : 0.975) : 1)

                // Soft translucent blobs give the orb the reference's glassy depth.
                Ellipse()
                    .fill(LinearGradient(colors: [
                        .white.opacity(0.52),
                        .white.opacity(0.08),
                        tint.opacity(0.10)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.60, height: side * 0.25)
                    .blur(radius: side * 0.018)
                    .rotationEffect(.degrees(drift ? -24 : -16))
                    .offset(x: -side * 0.10, y: -side * 0.22)
                    .blendMode(.screen)

                Circle()
                    .fill(RadialGradient(colors: [
                        .white.opacity(0.30),
                        .white.opacity(0.07),
                        .clear
                    ], center: .topLeading, startRadius: 0, endRadius: side * 0.72))
                    .padding(side * 0.035)

                // The idle orb signals a sustained magnetic change using only its rim.
                if !isMeasuring && proximitySignal {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    detectionTint.opacity(detectionPulse ? 1.0 : 0.40),
                                    .white.opacity(detectionPulse ? 0.72 : 0.24),
                                    detectionTint.opacity(detectionPulse ? 0.82 : 0.32)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: detectionPulse ? 2.8 : 1.4
                        )
                        .padding(side * 0.012)
                        .shadow(color: detectionTint.opacity(detectionPulse ? 0.72 : 0.24),
                                radius: detectionPulse ? 14 : 5)
                        .scaleEffect(detectionPulse ? 1.025 : 0.985)
                        .allowsHitTesting(false)
                }

                // Fine inner rim and a subtle refracted highlight.
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 0.8)
                    .padding(side * 0.055)
                Ellipse()
                    .fill(.white.opacity(0.24))
                    .frame(width: side * 0.28, height: side * 0.045)
                    .blur(radius: side * 0.012)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -side * 0.22, y: -side * 0.31)

                if !isMeasuring {
                    Image(systemName: "play.fill")
                        .font(.system(size: side * 0.065, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .shadow(color: .black.opacity(0.24), radius: 5)
                        .offset(y: side * 0.31)
                } else {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                        .padding(side * (0.12 + CGFloat(intensity) * 0.035))
                        .scaleEffect(drift ? 1.045 : 0.97)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .onAppear {
                if isMeasuring {
                    withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                        drift = true
                    }
                }
                if proximitySignal && !isMeasuring {
                    withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                        detectionPulse = true
                    }
                }
            }
            .onChange(of: proximitySignal) { _, detected in
                if detected && !isMeasuring {
                    withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                        detectionPulse = true
                    }
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                        detectionPulse = false
                    }
                }
            }
            .onChange(of: isMeasuring) { _, active in
                if active {
                    withAnimation(.spring(response: 0.48, dampingFraction: 0.68)) {
                        drift = true
                    }
                    withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                        drift = false
                    }
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                        drift = false
                    }
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.76), value: intensity)
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

