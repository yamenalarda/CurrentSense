import SwiftUI
import CurrentSenseCore

struct ContentView: View {
    @EnvironmentObject private var vm: MeasurementViewModel
    @State private var showSetup = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 720
            let availableWidth = max(0, geometry.size.width - 40)
            let circleSide = min(availableWidth, max(180, (geometry.size.height - (compact ? 230 : 270)) * 0.78))
            ZStack {
                BackgroundView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: compact ? 8 : 12) {
                    ModeSelector(selected: vm.mode, onSelect: vm.setMode)
                        .padding(.top, 2)

                    Button(action: vm.toggle) {
                        GlassCircle(phase: vm.snapshot.phase, level: vm.snapshot.level,
                                    progress: vm.snapshot.acquisitionProgress,
                                    title: circleText.0, subtitle: circleText.1)
                            .frame(width: circleSide, height: circleSide)
                    }
                    .buttonStyle(.plain)
                    .frame(width: circleSide, height: circleSide)
                    .accessibilityLabel("Measurement control")
                    .accessibilityValue(accessibilityState)
                    .accessibilityHint(vm.isRunning ? "Double tap to stop measuring" : "Double tap to start measuring")
                    .accessibilityIdentifier("measure.button")

                    ReadingsPanel(presentation: presentation, mode: vm.mode,
                                  audioEnabled: $vm.audioEnabled, onSetup: { showSetup = true })
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, compact ? 4 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
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
