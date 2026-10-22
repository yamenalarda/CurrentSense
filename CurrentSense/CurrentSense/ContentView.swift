import SwiftUI
import Charts
import UIKit

private enum MeasurementMode: String, CaseIterable, Identifiable {
    case dc = "DC"
    case ac = "AC"
    var id: String { rawValue }
}

private enum GlassStyle {
    static let background = LinearGradient(
        colors: [Color(red: 0.035, green: 0.055, blue: 0.10),
                 Color(red: 0.075, green: 0.10, blue: 0.17),
                 Color(red: 0.025, green: 0.035, blue: 0.07)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let cyan = Color(red: 0.38, green: 0.82, blue: 1.0)
    static let mint = Color(red: 0.40, green: 0.94, blue: 0.76)
}

struct ContentView: View {
    @StateObject private var sensor = MagnetometerService()
    @State private var mode: MeasurementMode = .dc
    @State private var baseline: SIMD3<Double>?
    @State private var distanceMillimeters = 5.0
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var showBaselineConfirmation = false

    private var currentVector: SIMD3<Double>? {
        guard let sample = sensor.latestSample else { return nil }
        return SIMD3(sample.x, sample.y, sample.z)
    }

    private var deltaVector: SIMD3<Double>? {
        guard let currentVector, let baseline else { return nil }
        return currentVector - baseline
    }

    private var deltaMagnitudeMicrotesla: Double? {
        guard let v = deltaVector else { return nil }
        return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    }

    // Ideal long straight wire only; not a calibrated current measurement.
    private var estimatedDCCurrent: Double? {
        guard mode == .dc, let deltaMagnitudeMicrotesla else { return nil }
        let r = distanceMillimeters / 1000
        let b = deltaMagnitudeMicrotesla * 1e-6
        let mu0 = 4 * Double.pi * 1e-7
        return 2 * Double.pi * r * b / mu0
    }

    private var observedSampleRate: Double? {
        guard sensor.samples.count >= 2,
              let first = sensor.samples.first, let last = sensor.samples.last else { return nil }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return nil }
        return Double(sensor.samples.count - 1) / duration
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    statusCard
                    modePicker
                    fieldCard
                    chartCard
                    baselineCard
                    if mode == .dc { dcEstimatorCard } else { acDiagnosticsCard }
                    sessionCard
                    safetyNote
                    Text("Designed by Yamen Arada")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background { GlassStyle.background.ignoresSafeArea() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard let url = sensor.exportCSV() else { return }
                        exportURL = url
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                    }
                    .disabled(sensor.samples.isEmpty)
                    .accessibilityLabel("Export CSV")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showShareSheet) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
            .alert("Baseline captured", isPresented: $showBaselineConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Baseline averaged from recent samples. Keep the phone in the same position and orientation.")
            }
            .onDisappear { sensor.stop() }
        }
        .preferredColorScheme(.dark)
        .tint(GlassStyle.cyan)
        .animation(.snappy(duration: 0.28), value: sensor.isRunning)
        .animation(.snappy(duration: 0.28), value: mode)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [GlassStyle.cyan.opacity(0.95), Color.blue.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 54, height: 54)
            .shadow(color: GlassStyle.cyan.opacity(0.22), radius: 18, y: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text("CurrentSense")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                Text("MAGNETIC FIELD LAB")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(GlassStyle.mint)
                .symbolEffect(.pulse, isActive: sensor.isRunning)
                .padding(11)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(sensor.isRunning ? GlassStyle.mint : Color.white.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .shadow(color: sensor.isRunning ? GlassStyle.mint.opacity(0.8) : .clear, radius: 7)
                    Text(sensor.isRunning ? "Live sensor" : "Sensor paused")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(sensor.isAvailable ? "READY" : "UNAVAILABLE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(sensor.isAvailable ? GlassStyle.mint : .orange)
                }

                HStack(spacing: 10) {
                    Button {
                        if sensor.isRunning {
                            withAnimation(.snappy) { sensor.stop() }
                        } else {
                            withAnimation(.snappy) { sensor.start() }
                        }
                    } label: {
                        Label(sensor.isRunning ? "Pause" : "Start measuring",
                              systemImage: sensor.isRunning ? "pause.fill" : "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.13))
                            .background(LinearGradient(colors: [GlassStyle.cyan, GlassStyle.mint],
                                                       startPoint: .leading, endPoint: .trailing),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(!sensor.isAvailable)

                    Button {
                        withAnimation(.snappy) {
                            sensor.clearSamples()
                            baseline = nil
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 46, height: 44)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1)))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(sensor.isRunning)
                    .accessibilityLabel("Clear samples")
                }

                if let error = sensor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 5) {
            ForEach(MeasurementMode.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { mode = item }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item == .dc ? "arrow.right" : "waveform")
                        Text(item.rawValue)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(mode == item ? .white : .white.opacity(0.55))
                    .background {
                        if mode == item {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(0.13))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16)))
                        }
                    }
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private var fieldCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TOTAL FIELD")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(.white.opacity(0.5))
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(sensor.latestSample.map { String(format: "%.2f", $0.magnitude) } ?? "—")
                                .font(.system(size: 43, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .minimumScaleFactor(0.65)
                                .lineLimit(1)
                            Text("µT")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(GlassStyle.cyan)
                        }
                        .foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(GlassStyle.cyan.opacity(0.9))
                        .frame(width: 60, height: 60)
                        .background(GlassStyle.cyan.opacity(0.09), in: Circle())
                        .overlay(Circle().stroke(GlassStyle.cyan.opacity(0.2)))
                }

                Rectangle().fill(.white.opacity(0.09)).frame(height: 1)

                HStack(spacing: 8) {
                    axisTile("X", value: sensor.latestSample?.x, tint: Color(red: 1, green: 0.43, blue: 0.48))
                    axisTile("Y", value: sensor.latestSample?.y, tint: GlassStyle.mint)
                    axisTile("Z", value: sensor.latestSample?.z, tint: GlassStyle.cyan)
                }

                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(GlassStyle.cyan)
                    if let delta = deltaMagnitudeMicrotesla {
                        Text("Δ Baseline")
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(String(format: "%.3f µT", delta))
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .contentTransition(.numericText())
                            .foregroundStyle(.white)
                    } else {
                        Text("Capture a baseline to compare field changes")
                            .foregroundStyle(.white.opacity(0.55))
                            .font(.footnote)
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func axisTile(_ axis: String, value: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(axis)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(value.map { String(format: "%+.2f", $0) } ?? "—")
                .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("µT")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(tint.opacity(0.18), lineWidth: 1))
    }

    private var chartCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Field history")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Magnetic magnitude over time")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Text("\(sensor.samples.count)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(GlassStyle.cyan)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(GlassStyle.cyan.opacity(0.1), in: Capsule())
                }

                if chartSamples.count >= 2 {
                    Chart {
                        ForEach(chartSamples) { sample in
                            AreaMark(x: .value("Time", sample.timestamp),
                                     yStart: .value("Floor", chartFloor),
                                     yEnd: .value("Field", sample.magnitude))
                                .foregroundStyle(LinearGradient(colors: [GlassStyle.cyan.opacity(0.22), GlassStyle.cyan.opacity(0.01)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Time", sample.timestamp),
                                     y: .value("Field (µT)", sample.magnitude))
                                .foregroundStyle(GlassStyle.cyan)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYScale(domain: chartFloor...chartCeiling)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.08))
                            AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) {
                            AxisGridLine().foregroundStyle(.white.opacity(0.04))
                            AxisValueLabel().foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .chartPlotStyle { plot in
                        plot.clipped()
                    }
                    .frame(height: 190)
                    .animation(.easeInOut(duration: 0.25), value: chartSamples.last?.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 27, weight: .light))
                            .foregroundStyle(GlassStyle.cyan.opacity(0.75))
                        Text("Waiting for measurements")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Text("Start measuring to build a live trace.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                }
            }
        }
    }

    private var chartFloor: Double {
        let minValue = chartSamples.map(\.magnitude).min() ?? 0
        let maxValue = chartSamples.map(\.magnitude).max() ?? 1
        let padding = max((maxValue - minValue) * 0.18, 0.5)
        return max(0, minValue - padding)
    }

    private var chartCeiling: Double {
        let minValue = chartSamples.map(\.magnitude).min() ?? 0
        let maxValue = chartSamples.map(\.magnitude).max() ?? 1
        return maxValue + max((maxValue - minValue) * 0.18, 0.5)
    }

    private var chartSamples: [MagneticSample] {
        let all = sensor.samples
        guard all.count > 500 else { return all }
        let step = max(1, all.count / 500)
        return Array(all.enumerated().compactMap { index, sample in
            index.isMultiple(of: step) ? sample : nil
        })
    }

    private var baselineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Baseline", subtitle: "Reference field for change detection", icon: "scope")
                Text(baseline == nil
                     ? "Place the phone in a fixed position with the test current switched off. Capture several samples for a steadier reference."
                     : "Reference saved. Keep the phone position and orientation unchanged while comparing measurements.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    guard sensor.isRunning, !sensor.samples.isEmpty else { return }
                    let recent = Array(sensor.samples.suffix(20))
                    let count = Double(recent.count)
                    baseline = SIMD3(
                        recent.reduce(0) { $0 + $1.x } / count,
                        recent.reduce(0) { $0 + $1.y } / count,
                        recent.reduce(0) { $0 + $1.z } / count
                    )
                    showBaselineConfirmation = true
                } label: {
                    Label(baseline == nil ? "Capture averaged baseline" : "Recapture baseline",
                          systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.12)))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!sensor.isRunning || sensor.samples.isEmpty)
            }
        }
    }

    private var dcEstimatorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("DC experiment", subtitle: "Theoretical estimate only", icon: "arrow.right")
                Text("Uses the ideal long, straight-wire equation. Real wiring geometry and phone sensor position can make this estimate substantially wrong.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))

                HStack {
                    Text("Sensor-to-wire distance")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.1f mm", distanceMillimeters))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(GlassStyle.cyan)
                }
                Slider(value: $distanceMillimeters, in: 2...30, step: 0.5)
                    .tint(GlassStyle.cyan)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(estimatedDCCurrent.map { String(format: "%.3f", $0) } ?? "—")
                        .font(.system(size: 31, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                    Text("A theoretical")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text("Do not treat this estimate as a calibrated ammeter reading.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
    }

    private var acDiagnosticsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("AC diagnostics", subtitle: "Sampling check, not an AC meter", icon: "waveform")
                metricRow("Observed app update rate", value: observedSampleRate.map { String(format: "%.2f Hz", $0) } ?? "—")
                metricRow("Mains frequency reference", value: "50 / 60 Hz")
                Text("The requested update interval is not a guarantee of hardware sample rate. Core Motion may filter or average the field, so this screen cannot establish AC waveform amplitude or RMS current.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    private var sessionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                sectionHeader("Session", subtitle: "Data captured by this app", icon: "clock")
                metricRow("Elapsed time", value: elapsedText)
                metricRow("Stored samples", value: "\(sensor.samples.count)")
                metricRow("CSV export", value: sensor.samples.isEmpty ? "No data yet" : "Ready")
                Text("CSV timestamps record when the app receives updates; they do not guarantee the exact hardware sampling instant.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private var elapsedText: String {
        guard let first = sensor.samples.first, let last = sensor.samples.last else { return "—" }
        return String(format: "%.1f s", last.timestamp.timeIntervalSince(first.timestamp))
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            Text("Research use only. Test with isolated, low-voltage, current-limited circuits. Never use this app to determine whether mains wiring is safe.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.15), lineWidth: 1))
    }

    private func sectionHeader(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GlassStyle.cyan)
                .frame(width: 35, height: 35)
                .background(GlassStyle.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.white.opacity(0.56))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        RoundedRectangle(cornerRadius: 23, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.015)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.19), .white.opacity(0.035)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.13), radius: 15, y: 7)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
