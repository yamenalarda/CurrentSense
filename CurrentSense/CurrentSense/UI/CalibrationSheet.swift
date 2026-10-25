import SwiftUI
import CurrentSenseCore

struct CalibrationSheet: View {
    @EnvironmentObject private var vm: MeasurementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var referenceText = ""
    @State private var distanceText = ""

    private var reference: Double? { Double(referenceText.replacingOccurrences(of: ",", with: ".")) }
    private var distance: Double? { Double(distanceText.replacingOccurrences(of: ",", with: ".")) }
    private var canCalibrate: Bool {
        vm.mode == .dc && vm.snapshot.phase == .measuring && vm.snapshot.isLive && (reference ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: Binding(get: { vm.geometryChoice }, set: { vm.setGeometryChoice($0) })) {
                        Text("Off").tag(GeometryChoice.off)
                        Text("Calibrated").tag(GeometryChoice.calibrated)
                        Text("Ideal wire").tag(GeometryChoice.idealWire)
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Current estimate") } footer: {
                    Text("With Off, the app reports the field change only. A current is shown only when the signal is strong and steady and the selected method can be justified.")
                }

                if vm.geometryChoice == .idealWire {
                    Section {
                        TextField("Distance to wire centre (cm)", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .onAppear { distanceText = String(format: "%.1f", vm.idealDistanceCm) }
                            .onChange(of: distanceText) { _, _ in if let d = distance, d > 0 { vm.setIdealDistance(cm: d) } }
                    } footer: {
                        Text("Assumes ONE long straight conductor carrying the whole current. A normal appliance cable has opposing currents that largely cancel, so this model is usually wrong by a large factor. Treat the result as a rough bound at best.")
                    }
                }

                Section {
                    Text("1. Start a DC measurement with the load switched off.\n2. Switch the load on at a known current (read it on a clamp meter).\n3. Hold the phone exactly where you will measure.\n4. Enter the clamp reading and tap Calibrate.")
                        .font(.footnote)
                    TextField("Reference current (A)", text: $referenceText).keyboardType(.decimalPad)
                    Button("Calibrate") { if let r = reference { vm.beginCalibration(referenceAmps: r) } }
                        .disabled(!canCalibrate)
                    if let p = vm.calibrationProgress { ProgressView(value: p) }
                    if let m = vm.calibrationMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
                    if let c = vm.calibration {
                        Text(String(format: "Stored: %.2f \u{00B5}T per A at %.2f A reference", c.sensitivityMicroteslaPerAmp, c.referenceCurrentAmps))
                            .font(.footnote)
                        Button("Remove calibration", role: .destructive) { vm.removeCalibration() }
                    }
                } header: { Text("Calibrate against a reference") } footer: {
                    Text("A calibration holds only for the same cable, position and phone orientation. Estimates above twice the calibrated current are refused.")
                }
            }
            .navigationTitle("Current setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
