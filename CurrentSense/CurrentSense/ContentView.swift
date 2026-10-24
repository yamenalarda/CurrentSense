import SwiftUI
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
                    Color(red: 0.003, green: 0.004, blue: 0.008),
                    Color(red: 0.010, green: 0.012, blue: 0.020),
                    Color(red: 0.002, green: 0.002, blue: 0.005)
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sensor = MagnetometerService()
    @StateObject private var toneFeedback = FieldToneFeedback()
    @State private var mode: MeasurementMode = .ac
    @State private var showCalculationSetup = false

    @AppStorage("CurrentSense.calculation.conductor")
    private var conductorRawValue = ConductorConfiguration.completeCable.rawValue
    @AppStorage("CurrentSense.calculation.reference")
    private var referenceRawValue = ReferenceSelection.knownDistance.rawValue
    @AppStorage("CurrentSense.calculation.distanceCm")
    private var referenceDistanceCm = "2.0"
    @AppStorage("CurrentSense.calculation.currentA")
    private var referenceCurrentA = "1.0"
    @AppStorage("CurrentSense.calibration.acSensitivity")
    private var acSensitivityMicroteslaPerAmp = 0.0
    @AppStorage("CurrentSense.calibration.dcSensitivity.v2")
    private var dcSensitivityMicroteslaPerAmp = 0.0

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
        if mode == .dc {
            // A 15-point rolling median reduces the effect of isolated spikes in DC estimates.
            let window = sensor.samples.suffix(15)
                .compactMap(\.filteredDeltaMagnitude)
                .filter { $0.isFinite && $0 >= 0 }
            guard window.count >= 7 else { return nil }
            return MagneticAnomalyDetector.median(window)
        }
        return sensor.latestSample?.filteredDeltaMagnitude
    }

    private var acScanLevel: ACFieldActivityLevel {
        ACFieldScanClassifier.classify(
            fieldChangeMicrotesla: fieldMagnitude,
            noiseSigmaMicrotesla: sensor.baselineNoiseSigmaMicrotesla,
            isMeasuring: sensor.isRunning,
            baselineCaptured: sensor.baselineCaptured
        )
    }

    private var acScanColor: Color {
        switch acScanLevel {
        case .weak: return .yellow
        case .moderate: return .orange
        case .strong: return .red
        case .capturingBaseline: return .yellow
        case .unavailable: return .gray
        case .idle, .noDetectableChange:
            return colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.40)
        }
    }

    private var measurementPanel: some View {
        Group {
            if mode == .ac { acFieldScanPanel } else { measurementBar }
        }
    }

    private var acFieldScanPanel: some View {
        let level = acScanLevel
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AC FIELD SCAN")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(mutedTextColor)
                    Text(level.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                Image(systemName: level.indicatesMagneticChange ? "waveform.path" : "waveform")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(acScanColor)
                    .frame(width: 48, height: 48)
                    .background(acScanColor.opacity(colorScheme == .dark ? 0.13 : 0.10), in: Circle())
                    .overlay(Circle().stroke(acScanColor.opacity(0.35), lineWidth: 1))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("FIELD RESPONSE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(mutedTextColor)
                    HStack(spacing: 5) {
                        ForEach(1...3, id: \.self) { step in
                            Capsule()
                                .fill(step <= level.strengthBars
                                      ? acScanColor
                                      : (colorScheme == .dark
                                         ? Color.white.opacity(0.12)
                                         : Color.black.opacity(0.10)))
                                .frame(height: 7)
                        }
                    }
                    Text(level.indicatesMagneticChange ? "Signal above threshold" : "Below detection threshold")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(acScanColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.10))
                    .frame(width: 1, height: 46)

                VStack(alignment: .leading, spacing: 7) {
                    Text("RELATIVE REACH")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(mutedTextColor)
                    Text(level.relativeReachTitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                    Text("Field-only")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Relative response only. Actual reach depends on current, cable geometry, orientation and phone position.")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("Reads magnetic changes, not voltage. Motors, magnets and phone movement can trigger it. No response does not mean voltage is absent.")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.orange.opacity(0.95) : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.black.opacity(0.54), Color.white.opacity(0.025)]
                                : [.white.opacity(0.72), .white.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(
                    colors: colorScheme == .dark
                        ? [.white.opacity(0.25), .white.opacity(0.05)]
                        : [.white.opacity(0.90), .black.opacity(0.07)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1)
        }
        .shadow(color: acScanColor.opacity(0.10), radius: 18, y: 7)
        .animation(.easeInOut(duration: 0.25), value: level)
    }

    private var fieldColor: Color { FieldPalette.color(for: fieldMagnitude ?? 0) }

    private func formattedCurrent(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value > 0 && value < 0.0001 { return "<0.0001" }
        if value < 0.01 { return String(format: "%.4f", value) }
        if value < 0.1 { return String(format: "%.3f", value) }
        return String(format: "%.2f", value)
    }

    private func formattedDistance(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        if value < 0.001 { return "<0.001" }
        if value < 0.1 { return String(format: "%.3f", value) }
        return String(format: "%.1f", value)
    }

    private var conductorConfiguration: ConductorConfiguration {
        ConductorConfiguration(rawValue: conductorRawValue) ?? .singleConductor
    }

    private var estimateReference: EstimationReference {
        switch conductorConfiguration {
        case .completeCable:
            let sensitivity = mode == .ac
                ? acSensitivityMicroteslaPerAmp
                : dcSensitivityMicroteslaPerAmp
            return sensitivity.isFinite && sensitivity > 0
                ? .empiricalMicroteslaPerAmp(sensitivity)
                : .missing
        case .singleConductor:
            guard let reference = ReferenceSelection(rawValue: referenceRawValue) else {
                return .invalid
            }
            switch reference {
            case .knownDistance:
                guard let distance = NumericInput.parse(referenceDistanceCm) else { return .invalid }
                return .knownDistanceCentimeters(distance)
            case .knownCurrent:
                guard let current = NumericInput.parse(referenceCurrentA) else { return .invalid }
                return .knownCurrentAmperes(current)
            }
        }
    }

    private var estimate: CurrentEstimate {
        CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: fieldMagnitude,
            isAC: mode == .ac,
            conductor: conductorConfiguration,
            reference: estimateReference,
            sensorCalibrationQuality: sensor.calibrationQuality,
            baselineNoiseSigmaMicrotesla: sensor.baselineNoiseSigmaMicrotesla
        )
    }

    private var currentMetricTitle: String {
        estimate.currentDetail.contains("Entered reference") ? "REFERENCE CURRENT" : "CURRENT"
    }

    private var distanceMetricTitle: String {
        estimate.distanceDetail.contains("Entered reference") ? "REFERENCE DISTANCE" : "DISTANCE"
    }

    var body: some View {
        GeometryReader { geometry in
            contentLayout(in: geometry)
        }
        .tint(colorScheme == .dark ? .white : .black)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: sensor.isRunning)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.45, dampingFraction: 0.76), value: fieldMagnitude)
        .onAppear {
            if scenePhase == .active {
                sensor.startMonitoring()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sensor.startMonitoring()
            } else {
                sensor.stopMonitoring()
                toneFeedback.stopTone()
            }
        }
        .onChange(of: fieldMagnitude) { _, value in
            toneFeedback.update(
                fieldChangeMicrotesla: value,
                measuring: sensor.isRunning,
                minimumThresholdMicrotesla: sensor.minimumUsableFieldChangeMicrotesla
            )
        }
        .onChange(of: sensor.isRunning) { _, isRunning in
            if !isRunning {
                toneFeedback.stopTone()
            }
        }
        .onDisappear {
            sensor.stopMonitoring()
            toneFeedback.stopTone()
        }
        .sheet(isPresented: $showCalculationSetup) {
            calculationSettingsSheet
        }
    }

    private func contentLayout(in geometry: GeometryProxy) -> some View {
        ZStack {
            FieldPalette.background(for: colorScheme).ignoresSafeArea()
            ambientGlow
            VStack(spacing: 0) {
                controlRow
                Spacer(minLength: 12)
                measurementOrb(in: geometry)
                measurementInstructions
                Spacer(minLength: 16)
                measurementPanel
                    .padding(.horizontal, 18)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom == 0 ? 14 : 8, 8))
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            modePicker
            Button {
                showCalculationSetup = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().fill(colorScheme == .dark
                        ? Color.black.opacity(0.40) : Color.white.opacity(0.06)))
                    .overlay(Circle().stroke(
                        colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10),
                        lineWidth: 1
                    ))
            }
            .accessibilityLabel("Calculation settings")
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
    }

    private func measurementOrb(in geometry: GeometryProxy) -> some View {
        FieldOrb(
            isMeasuring: sensor.isRunning,
            magnitude: fieldMagnitude ?? 0,
            tint: fieldColor,
            proximitySignal: sensor.magneticSourceDetected,
            colorScheme: colorScheme
        )
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
    }

    private var measurementInstructions: some View {
        VStack(spacing: 8) {
            Text(
                !sensor.isRunning
                    ? (mode == .ac ? "Tap the circle to start field scan" : "Tap the circle to begin")
                    : (!sensor.baselineCaptured
                        ? "Capturing baseline — hold still away from cable"
                        : (mode == .ac
                            ? "Scan slowly along the insulated cable"
                            : "Baseline ready — move phone near the conductor"))
            )
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(primaryTextColor)
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)

            Text(
                !sensor.isRunning
                    ? (mode == .ac
                        ? "AC shows relative magnetic activity, not voltage or current numbers."
                        : "Start away from the conductor and hold still while the baseline is captured.")
                    : (!sensor.baselineCaptured
                        ? "Keep the phone still until the reference is ready."
                        : (mode == .ac
                            ? "Keep the phone still at each point; movement itself can change the field."
                            : "DC estimates use a rolling median. Keep position and orientation fixed."))
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
                    Circle()
                        .fill(sensor.baselineCaptured ? fieldColor : .yellow)
                        .frame(width: 6, height: 6)
                    Text(sensor.baselineCaptured
                         ? (mode == .ac
                            ? acScanLevel.title.uppercased()
                            : (fieldMagnitude == nil ? "STABILIZING DC SIGNAL" : "STABLE DC WINDOW"))
                         : "CAPTURING BASELINE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(sensor.baselineCaptured
                                         ? (mode == .ac ? acScanColor : fieldColor)
                                         : .yellow)
                    Text("· CAL \\(sensor.calibrationQuality.uppercased())")
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

            if sensor.isRunning, mode == .dc, let caution = estimate.caution {
                Text(caution)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.62) : .black.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    private var calculationSettingsSheet: some View {
        CalculationSettingsView(
            sensor: sensor,
            isAC: mode == .ac,
            onCalibrate: { referenceAmps, fieldMicrotesla, acMode in
                saveCalibration(
                    referenceAmps: referenceAmps,
                    fieldMicrotesla: fieldMicrotesla,
                    isAC: acMode
                )
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func saveCalibration(referenceAmps: Double, fieldMicrotesla: Double, isAC: Bool) {
        let sensitivity = fieldMicrotesla / referenceAmps
        guard sensitivity.isFinite, sensitivity > 0 else { return }
        if isAC {
            acSensitivityMicroteslaPerAmp = sensitivity
        } else {
            dcSensitivityMicroteslaPerAmp = sensitivity
        }
    }

    private var ambientGlow: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(fieldColor.opacity(sensor.isRunning
                        ? (colorScheme == .dark ? 0.10 : 0.17)
                        : (colorScheme == .dark ? 0.035 : 0.08)))
                    .frame(width: proxy.size.width * 0.95)
                    .blur(radius: 100)
                    .offset(x: -proxy.size.width * 0.25, y: -proxy.size.height * 0.08)
                Circle()
                    .fill(Color.blue.opacity(colorScheme == .dark ? 0.025 : 0.12))
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
        .overlay(Capsule().fill(colorScheme == .dark
            ? Color.black.opacity(0.48) : Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(
            colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10),
            lineWidth: 1
        ))
    }

    private var measurementBar: some View {
        HStack(spacing: 0) {
            metricColumn(
                title: currentMetricTitle,
                value: estimate.currentAmperes.map { formattedCurrent($0) } ?? "—",
                unit: "A",
                detail: estimate.currentDetail,
                tint: estimate.currentAmperes == nil ? secondaryTextColor : fieldColor
            )
            separator
            metricColumn(
                title: "FIELD CHANGE",
                value: fieldMagnitude.map { String(format: "%.3f", $0) } ?? "—",
                unit: "µT",
                detail: !sensor.isRunning
                    ? "Start measuring"
                    : (!sensor.baselineCaptured
                        ? "Capturing baseline"
                        : (mode == .dc && fieldMagnitude == nil
                            ? "Stabilizing DC signal"
                            : ((fieldMagnitude ?? 0) < sensor.minimumUsableFieldChangeMicrotesla
                                ? String(format: "Below %.3f µT noise threshold",
                                         sensor.minimumUsableFieldChangeMicrotesla)
                                : (mode == .dc ? "1.5 s rolling median" : "Filtered vs baseline")))),
                tint: fieldColor
            )
            separator
            metricColumn(
                title: distanceMetricTitle,
                value: estimate.distanceCentimeters.map { formattedDistance($0) } ?? "—",
                unit: "cm",
                detail: estimate.distanceDetail,
                tint: estimate.distanceCentimeters == nil ? secondaryTextColor : fieldColor
            )
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
                                ? [Color.black.opacity(0.48), Color.white.opacity(0.025)]
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
                toneFeedback.stopTone()
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
    let colorScheme: ColorScheme
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

                // Spectral edge reflections create the glossy, holographic glass rim.
                Circle()
                    .stroke(
                        AngularGradient(colors: [
                            Color.cyan.opacity(colorScheme == .dark ? 0.66 : 0.42),
                            Color.blue.opacity(0.14),
                            Color.purple.opacity(colorScheme == .dark ? 0.58 : 0.36),
                            Color.pink.opacity(colorScheme == .dark ? 0.64 : 0.40),
                            Color.orange.opacity(0.34),
                            Color.cyan.opacity(colorScheme == .dark ? 0.66 : 0.42)
                        ], center: .center),
                        lineWidth: side * 0.038
                    )
                    .padding(side * 0.018)
                    .blur(radius: side * 0.012)
                    .shadow(color: Color.purple.opacity(0.20), radius: side * 0.06)

                // Outer transparent glass body, with a soft rim.
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(
                            LinearGradient(colors: [
                                .white.opacity(0.12),
                                tint.opacity(0.045),
                                .white.opacity(0.015),
                                tint.opacity(0.07)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    }
                    .overlay {
                        Circle().stroke(
                            LinearGradient(colors: [
                                .white.opacity(0.82),
                                .white.opacity(0.09),
                                tint.opacity(0.42),
                                .white.opacity(0.30)
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

                // Soft refracted hues, like colored lights reflecting through polished glass.
                Circle()
                    .fill(AngularGradient(colors: [
                        Color.cyan.opacity(colorScheme == .dark ? 0.17 : 0.10),
                        Color.blue.opacity(0.045),
                        Color.purple.opacity(colorScheme == .dark ? 0.19 : 0.10),
                        Color.pink.opacity(colorScheme == .dark ? 0.15 : 0.08),
                        Color.orange.opacity(0.06),
                        Color.cyan.opacity(colorScheme == .dark ? 0.17 : 0.10)
                    ], center: .center))
                    .padding(side * 0.052)
                    .blur(radius: side * 0.025)
                    .mask(Circle().padding(side * 0.035))

                // Liquid, layered color inside the glass: simulation heatmap colors.
                Circle()
                    .fill(
                        AngularGradient(stops: [
                            .init(color: FieldPalette.color(for: magnitude * 0.18).opacity(0.16), location: 0.00),
                            .init(color: FieldPalette.color(for: magnitude * 0.42).opacity(0.26), location: 0.18),
                            .init(color: FieldPalette.color(for: magnitude * 0.68).opacity(0.22), location: 0.38),
                            .init(color: FieldPalette.color(for: magnitude).opacity(0.34), location: 0.60),
                            .init(color: FieldPalette.color(for: magnitude * 0.35).opacity(0.20), location: 0.82),
                            .init(color: FieldPalette.color(for: magnitude * 0.18).opacity(0.16), location: 1.00)
                        ], center: .center, startAngle: .degrees(drift ? 25 : -25),
                           endAngle: .degrees(drift ? 385 : 335))
                    )
                    .padding(side * 0.055)
                    .blur(radius: side * 0.012)
                    .mask(Circle().padding(side * 0.035))
                    .scaleEffect(isMeasuring ? (drift ? 1.025 : 0.975) : 1)

                // Broad studio-light reflection across the glass surface.
                Ellipse()
                    .fill(LinearGradient(colors: [
                        .white.opacity(colorScheme == .dark ? 0.46 : 0.34),
                        .white.opacity(0.075),
                        Color.cyan.opacity(0.05),
                        .clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.68, height: side * 0.28)
                    .blur(radius: side * 0.014)
                    .rotationEffect(.degrees(drift ? -23 : -16))
                    .offset(x: -side * 0.10, y: -side * 0.22)
                    .blendMode(.screen)

                // A secondary cool highlight balances the warmer edge reflections.
                Ellipse()
                    .fill(LinearGradient(colors: [
                        Color.cyan.opacity(colorScheme == .dark ? 0.23 : 0.14),
                        Color.purple.opacity(0.08),
                        .clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.24, height: side * 0.42)
                    .blur(radius: side * 0.035)
                    .rotationEffect(.degrees(24))
                    .offset(x: side * 0.29, y: -side * 0.015)
                    .blendMode(.screen)

                Circle()
                    .fill(RadialGradient(colors: [
                        .white.opacity(0.18),
                        .white.opacity(0.035),
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
                        detectionPulse = false
                    }
                    withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                        drift = false
                    }
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                        drift = false
                    }
                    if proximitySignal {
                        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                            detectionPulse = true
                        }
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



private enum NumericInput {
    static func parse(_ text: String) -> Double? {
        var value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        guard !value.isEmpty else { return nil }

        if value.contains(",") && value.contains(".") {
            let comma = value.lastIndex(of: ",")!
            let dot = value.lastIndex(of: ".")!
            if comma > dot {
                value = value.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else {
                value = value.replacingOccurrences(of: ",", with: "")
            }
        } else if value.contains(",") {
            value = value.replacingOccurrences(of: ",", with: ".")
        }

        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

private struct CalculationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var sensor: MagnetometerService

    let isAC: Bool
    let onCalibrate: (Double, Double, Bool) -> Void

    @AppStorage("CurrentSense.calculation.conductor")
    private var conductorRawValue = ConductorConfiguration.completeCable.rawValue
    @AppStorage("CurrentSense.calculation.reference")
    private var referenceRawValue = ReferenceSelection.knownDistance.rawValue
    @AppStorage("CurrentSense.calculation.distanceCm")
    private var referenceDistanceCm = "2.0"
    @AppStorage("CurrentSense.calculation.currentA")
    private var referenceCurrentA = "1.0"
    @AppStorage("CurrentSense.calibration.acSensitivity")
    private var acSensitivityMicroteslaPerAmp = 0.0
    @AppStorage("CurrentSense.calibration.dcSensitivity.v2")
    private var dcSensitivityMicroteslaPerAmp = 0.0

    @State private var calibrationReferenceCurrentA = "1.0"
    @State private var calibrationFeedback: String?

    private var conductor: ConductorConfiguration {
        ConductorConfiguration(rawValue: conductorRawValue) ?? .singleConductor
    }

    private var currentSensitivity: Double {
        isAC ? acSensitivityMicroteslaPerAmp : dcSensitivityMicroteslaPerAmp
    }

    private var stableCalibrationField: Double? {
        let window = sensor.samples.suffix(15)
            .compactMap(\.filteredDeltaMagnitude)
            .filter { $0.isFinite && $0 >= 0 }
        guard window.count >= 7 else { return nil }
        return MagneticAnomalyDetector.median(window)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAC {
                    Section("AC field scan") {
                        Text("AC mode is qualitative: it classifies the magnetic-field response as none, weak, moderate or strong. It intentionally does not display amperes, centimeters or voltage numbers.")
                        Text("A real NCV tester senses an electric field. CurrentSense reads magnetic changes, which can also come from motors, magnets or phone movement; it cannot verify that a cable is live or prove that voltage is absent.")
                        Text("Use a properly rated voltage tester and the correct electrical safety procedure when checking for dangerous voltage.")
                    }
                } else {
                Section("Conductor setup") {
                    Picker("Wiring", selection: $conductorRawValue) {
                        ForEach(ConductorConfiguration.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    if conductor == .singleConductor {
                        Picker("Known reference", selection: $referenceRawValue) {
                            ForEach(ReferenceSelection.allCases) { item in
                                Text(item.title).tag(item.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        if referenceRawValue == ReferenceSelection.knownDistance.rawValue {
                            TextField("Sensor-to-wire distance (cm)", text: $referenceDistanceCm)
                                .keyboardType(.decimalPad)
                            Text("Enter the estimated distance from the iPhone's magnetic sensor to the conductor center, including insulation and sensor depth.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("Known reference current (A)", text: $referenceCurrentA)
                                .keyboardType(.decimalPad)
                            Text("This current is shown as a reference input; only distance is calculated from the field.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Text("The physical model applies only to a long, isolated, straight DC conductor. It is not valid for a complete phase/neutral cable or tightly bundled wires.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The phase and neutral inside a complete cable can cancel each other's magnetic fields. Use an empirical reference calibration at the exact phone position.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextField("Known reference current (A)", text: $calibrationReferenceCurrentA)
                            .keyboardType(.decimalPad)

                        HStack {
                            Text("Current-mode calibration")
                            Spacer()
                            Text(isAC ? "AC" : "DC")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Saved sensitivity")
                            Spacer()
                            Text(currentSensitivity > 0
                                 ? String(format: "%.3f µT/A", currentSensitivity)
                                 : "Not calibrated")
                                .foregroundStyle(currentSensitivity > 0 ? .primary : .secondary)
                        }

                        Button("Calibrate from current reading") {
                            calibrate()
                        }
                        .disabled(
                            !sensor.isRunning ||
                            !sensor.baselineCaptured ||
                            (stableCalibrationField ?? 0) <
                                sensor.minimumUsableFieldChangeMicrotesla
                        )

                        if let calibrationFeedback {
                            Text(calibrationFeedback)
                                .font(.footnote)
                                .foregroundStyle(calibrationFeedback.hasPrefix("Saved")
                                    ? .green : .orange)
                        }

                        Text("Use a known current from a suitable reference meter. Keep the same cable, load type, frequency, phone position, case, and orientation when measuring later. AC calibration is not a guarantee of true RMS accuracy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                }
                Section("Live sensor diagnostics") {
                    HStack {
                        Text("Baseline")
                        Spacer()
                        Text(sensor.baselineCaptured
                             ? "Ready"
                             : (sensor.isRunning ? "Capturing" : "Not captured"))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Core Motion accuracy")
                        Spacer()
                        Text(sensor.calibrationQuality)
                            .foregroundStyle(sensor.calibrationQuality == "High"
                                ? Color.primary : Color.orange)
                    }
                    HStack {
                        Text("Raw total field")
                        Spacer()
                        Text(sensor.latestSample.map {
                            String(format: "%.2f µT", $0.magnitude)
                        } ?? "—")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Raw change")
                        Spacer()
                        Text(sensor.latestSample?.deltaMagnitude.map {
                            String(format: "%.3f µT", $0)
                        } ?? "—")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Filtered change")
                        Spacer()
                        Text(sensor.latestSample?.filteredDeltaMagnitude.map {
                            String(format: "%.3f µT", $0)
                        } ?? "—")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Baseline noise (MAD)")
                        Spacer()
                        Text(sensor.baselineNoiseSigmaMicrotesla.map {
                            String(format: "%.3f µT", $0)
                        } ?? "—")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Actual sample rate")
                        Spacer()
                        Text(sensor.observedDeliveryRateHz.map {
                            String(format: "%.1f Hz", $0)
                        } ?? "—")
                            .monospacedDigit()
                    }
                    if let sample = sensor.latestSample {
                        Text(String(format: "Device axes  X %.2f  Y %.2f  Z %.2f µT",
                                    sample.x, sample.y, sample.z))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Zero change means the sensor sees little difference from its captured baseline; it does not prove that current is zero. Start the measurement away from the cable, hold still until the baseline is ready, then move the phone close to the insulated cable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("The main signal now uses raw CMMagnetometerData, while Core Motion accuracy is displayed only as auxiliary metadata. A charger cable can still produce little external field because its paired conductors partly cancel. The requested update interval is not the actual sample rate; use the rate above. The 80 Hz request may reduce synchronization with 50 Hz mains in some devices, but cannot reconstruct a true AC RMS waveform.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Measurement limits") {
                    if isAC {
                        Text("Field-response bands are relative, not calibrated distances. A stronger field can result from higher current, cable geometry, orientation or phone position—not only from being closer.")
                        Text("This app is not a safety-rated NCV or voltage detector. A weak or absent response must never be interpreted as safe or de-energized.")
                    } else {
                        Text("One magnetic-field reading cannot independently determine both current and distance. The app uses a straight-wire model only for an isolated DC conductor, or a cable-specific sensitivity calibrated against a known current.")
                        Text("Readings below 0.5 µT, or below five times the measured baseline noise, are treated as too weak. Low or uncalibrated sensor status lowers confidence. Estimates need validation against a clamp meter.")
                    }
                }
            }
            .scrollContentBackground(colorScheme == .dark ? .hidden : .visible)
            .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Calculation Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(colorScheme == .dark ? .white : .black)
    }

    private func calibrate() {
        guard let referenceAmps = NumericInput.parse(calibrationReferenceCurrentA),
              referenceAmps > 0,
              referenceAmps <= CurrentEstimateCalculator.maximumReferenceCurrentAmperes else {
            calibrationFeedback = "Enter a valid positive reference current."
            return
        }
        guard sensor.isRunning, sensor.baselineCaptured else {
            calibrationFeedback = "Start measurement and wait for a stable field reading."
            return
        }
        guard let field = stableCalibrationField else {
            calibrationFeedback = "Hold the phone still to collect a stable 1.5-second window."
            return
        }
        guard field.isFinite, field >= sensor.minimumUsableFieldChangeMicrotesla else {
            calibrationFeedback = "The signal is below the noise-adjusted calibration threshold."
            return
        }
        let sensitivity = field / referenceAmps
        guard sensitivity.isFinite, sensitivity > 0 else {
            calibrationFeedback = "The current field reading cannot calibrate this setup."
            return
        }
        onCalibrate(referenceAmps, field, isAC)
        calibrationFeedback = "Saved sensitivity: \(String(format: "%.3f", sensitivity)) µT/A for \(isAC ? "AC" : "DC")."
    }
}
