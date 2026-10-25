import SwiftUI
import CurrentSenseCore

struct ContentView: View {
    @EnvironmentObject private var vm: MeasurementViewModel
    @State private var showSetup = false

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 18) {
                ModeSelector(selected: vm.mode, onSelect: vm.setMode)
                    .padding(.top, 4)

                Button(action: vm.toggle) {
                    GlassCircle(phase: vm.snapshot.phase, level: vm.snapshot.level,
                                progress: vm.snapshot.acquisitionProgress,
                                title: circleText.0, subtitle: circleText.1)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Measurement control")
                .accessibilityValue(accessibilityState)
                .accessibilityHint(vm.isRunning ? "Double tap to stop measuring" : "Double tap to start measuring")
                .accessibilityIdentifier("measure.button")

                ReadingsPanel(presentation: presentation, mode: vm.mode,
                              audioEnabled: $vm.audioEnabled, onSetup: { showSetup = true })
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSetup) {
            CalibrationSheet().environmentObject(vm)
        }
    }

    private var presentation: ReadingsPresentation {
        var p = ReadingsPresenter.present(vm.snapshot)
        if let n = vm.notice, !vm.isRunning { p.status = n }
        return p
    }

    private var circleText: (String, String) {
        let s = vm.snapshot
        switch s.phase {
        case .idle, .stopped: return ("Tap to measure", "")
        case .acquiring: return ("Baseline", "Hold still")
        case .measuring:
            if s.issue == .holdStill { return ("Paused", "Hold still") }
            if !s.isLive || s.issue != .none { return ("Paused", "") }
            if s.mode == .ac {
                switch s.fieldPresent {
                case true?: return ("Detected", "")
                case false?: return ("Quiet", "")
                case nil: return ("Measuring", "")
                }
            }
            return ("Measuring", "")
        }
    }

    private var accessibilityState: String {
        switch vm.snapshot.phase {
        case .idle: return "Idle"
        case .acquiring: return "Taking baseline"
        case .measuring: return vm.snapshot.isLive ? "Measuring" : "Signal lost"
        case .stopped: return "Stopped"
        }
    }
}
