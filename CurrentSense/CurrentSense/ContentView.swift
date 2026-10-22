import SwiftUI
import Charts
import UIKit

private enum MeasurementMode: String, CaseIterable, Identifiable {
    case dc = "DC"
    case ac = "AC"

    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var sensor = MagnetometerService()
    @State private var mode: MeasurementMode = .dc
    @State private var baseline: SIMD3<Double>?
    @State private var distanceMillimeters: Double = 5.0
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var sessionStart = Date()

    private var currentVector: SIMD3<Double>? {
        guard let sample = sensor.latestSample else { return nil }
        return SIMD3(sample.x, sample.y, sample.z)
    }

    private var deltaVector: SIMD3<Double>? {
        guard let currentVector, let baseline else { return nil }
        return currentVector - baseline
    }

    private var deltaMagnitudeMicrotesla: Double? {
        guard let deltaVector else { return nil }
        return sqrt(deltaVector.x * deltaVector.x
                    + deltaVector.y * deltaVector.y
                    + deltaVector.z * deltaVector.z)
    }

    // For an ideal long, straight wire: I = 2πrB/μ0.
    // B is the change in field magnitude in tesla, r in metres.
    // This is only a rough experimental estimate and assumes suitable geometry.
    private var estimatedDCCurrent: Double? {
        guard mode == .dc, let deltaMagnitudeMicrotesla else { return nil }
        let rMeters = distanceMillimeters / 1000.0
        let bTesla = deltaMagnitudeMicrotesla * 1e-6
        let mu0 = 4.0 * Double.pi * 1e-7
        return (2.0 * Double.pi * rMeters * bTesla) / mu0
    }

    private var observedSampleRate: Double? {
        guard sensor.samples.count >= 2,
              let first = sensor.samples.first,
              let last = sensor.samples.last else { return nil }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return nil }
        return Double(sensor.samples.count - 1) / duration
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    modePicker
                    fieldCard
                    chartCard
                    baselineCard
                    if mode == .dc {
                        dcEstimatorCard
                    } else {
                        acDiagnosticsCard
                    }
                    recordingCard
                    safetyNote
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("CurrentSense")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if let url = sensor.exportCSV() {
                            exportURL = url
                            showShareSheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(sensor.samples.isEmpty)
                    .accessibilityLabel("Export CSV")
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
            .onDisappear {
                sensor.stop()
            }
        }
        .tint(.blue)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(sensor.isRunning ? .green : .secondary)
                    .frame(width: 9, height: 9)
                Text(sensor.isRunning ? "Magnetometer running" : "Sensor stopped")
                    .font(.headline)
                Spacer()
                Text(sensor.isAvailable ? "Available" : "Unavailable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(sensor.isAvailable ? .green : .red)
            }

            HStack(spacing: 10) {
                Button(sensor.isRunning ? "Stop" : "Start recording") {
                    if sensor.isRunning {
                        sensor.stop()
                    } else {
                        sessionStart = Date()
                        sensor.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sensor.isAvailable)

                Button("Clear") {
                    sensor.clearSamples()
                    baseline = nil
                }
                .buttonStyle(.bordered)
                .disabled(sensor.isRunning)
            }

            if let error = sensor.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(MeasurementMode.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 2)
    }

    private var fieldCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Magnetic field")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sensor.latestSample.map { String(format: "%.2f", $0.magnitude) } ?? "—")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("µT")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                axisValue("X", value: sensor.latestSample?.x)
                axisValue("Y", value: sensor.latestSample?.y)
                axisValue("Z", value: sensor.latestSample?.z)
            }

            if let delta = deltaMagnitudeMicrotesla {
                Label(String(format: "Change from baseline: %.3f µT", delta), systemImage: "arrow.left.arrow.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Capture a baseline to show field change.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func axisValue(_ axis: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(axis)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.2f", $0) } ?? "—")
                .font(.system(.body, design: .monospaced))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Field over time")
                    .font(.headline)
                Spacer()
                Text("\(sensor.samples.count) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if sensor.samples.count >= 2 {
                Chart {
                    ForEach(chartSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("µT", sample.magnitude)
                        )
                        .foregroundStyle(.blue)
                    }
                }
                .chartYAxisLabel("µT")
                .frame(height: 180)
            } else {
                ContentUnavailableView("Waiting for samples", systemImage: "waveform.path", description: Text("Start recording to display the field trace."))
                    .frame(height: 150)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var chartSamples: [MagneticSample] {
        // Keep chart rendering responsive during longer recordings.
        let all = sensor.samples
        guard all.count > 800 else { return all }
        let strideSize = max(1, all.count / 800)
        return Array(all.enumerated().compactMap { index, sample in
            index.isMultiple(of: strideSize) ? sample : nil
        })
    }

    private var baselineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Baseline")
                .font(.headline)
            Text(baseline == nil
                 ? "Keep the phone still with the current switched off, then capture the baseline."
                 : "Baseline captured. Keep the phone in the same position and orientation during measurement.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Capture baseline from latest sample") {
                guard let currentVector else { return }
                baseline = currentVector
            }
            .buttonStyle(.bordered)
            .disabled(sensor.latestSample == nil)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var dcEstimatorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Experimental DC estimate")
                .font(.headline)
            Text("Assumes a long, straight wire and suitable field geometry. The result is not calibrated and may be inaccurate.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("Sensor-to-wire distance")
                Spacer()
                Text(String(format: "%.1f mm", distanceMillimeters))
                    .monospacedDigit()
            }
            Slider(value: $distanceMillimeters, in: 2...30, step: 0.5)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(estimatedDCCurrent.map { String(format: "%.3f", $0) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("A (theoretical)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("This estimate uses the vector change from the captured baseline. Nearby return wires, steel, magnets, phone movement, and unknown sensor location can invalidate it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var acDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AC sampling diagnostics")
                .font(.headline)

            metricRow("Observed app sample rate", value: observedSampleRate.map { String(format: "%.2f Hz", $0) } ?? "—")
            metricRow("Nominal grid frequency", value: "50 / 60 Hz")

            Text("A sample rate alone does not prove that the sensor captures AC waveform amplitude. Core Motion may filter or average the field internally. Do not interpret this screen as an AC RMS current meter.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session")
                .font(.headline)
            metricRow("Elapsed", value: elapsedText)
            metricRow("Stored samples", value: "\(sensor.samples.count)")
            metricRow("CSV export", value: sensor.samples.isEmpty ? "No data yet" : "Ready")
            Text("CSV includes app timestamps and the three field components. Timestamps are recorded when the app receives each update, not as a guarantee of hardware sampling instants.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var elapsedText: String {
        guard let first = sensor.samples.first, let last = sensor.samples.last else { return "—" }
        return String(format: "%.1f s", last.timestamp.timeIntervalSince(first.timestamp))
    }

    private var safetyNote: some View {
        Label {
            Text("Research use only. Use isolated, low-voltage, current-limited test circuits. Never use this app to check whether mains wiring is safe.")
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
