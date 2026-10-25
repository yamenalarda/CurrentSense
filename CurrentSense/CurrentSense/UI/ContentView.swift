import SwiftUI
import CurrentSenseCore

struct ContentView: View {
    @EnvironmentObject private var vm: MeasurementViewModel
    @State private var showSetup = false

    var body: some View {
        GeometryReader { geometry in
            // Resolve one usable content width and give every control that same width boundary.
            // Do not apply horizontal padding after a screen-width frame; that can enlarge the
            // resulting view beyond the viewport and make the whole composition look shifted.
            // GeometryReader now occupies the system-safe viewport, not the camera/notch area.
            // BackgroundView still extends behind the entire display.
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            let sideInset = min(20, screenWidth * 0.06)
            let contentWidth = max(1, screenWidth - sideInset * 2)
            let compact = screenHeight < 720
            let circleLimit = max(168, (screenHeight - (compact ? 250 : 290)) * 0.72)
            let circleSide = min(contentWidth, circleLimit)

            ZStack {
                BackgroundView()

                ScrollView(.vertical) {
                    VStack(alignment: .center, spacing: compact ? 8 : 12) {
                        ModeSelector(selected: vm.mode, onSelect: vm.setMode)
                            .frame(width: min(260, contentWidth))
                            .padding(.top, 10)

                        Button(action: vm.toggle) {
                            GlassCircle(phase: vm.snapshot.phase, level: vm.snapshot.level,
                                        progress: vm.snapshot.acquisitionProgress,
                                        title: circleText.0, subtitle: circleText.1)
                                .frame(width: circleSide, height: circleSide)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: circleSide, height: circleSide)
                        .accessibilityLabel("Measurement control")
                        .accessibilityValue(accessibilityState)
                        .accessibilityHint(vm.isRunning ? "Double tap to stop measuring" : "Double tap to start measuring")
                        .accessibilityIdentifier("measure.button")

                        ReadingsPanel(presentation: presentation, mode: vm.mode,
                                      audioEnabled: $vm.audioEnabled,
                                      appearancePreference: $vm.appearancePreference,
                                      onSetup: { showSetup = true })
                            .frame(width: contentWidth)
                    }
                    // The inner column has a fixed, bounded width. Its outer frame occupies the
                    // viewport and explicitly centers it, rather than relying on nested padding.
                    .frame(width: contentWidth)
                    .padding(.vertical, compact ? 4 : 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.hidden)
                .frame(width: screenWidth, height: screenHeight)
            }
            .frame(width: screenWidth, height: screenHeight)
            .clipped()
        }
        // The background bleeds edge-to-edge, but the controls stay below the Dynamic Island
        // and above the home-indicator area. Do not ignore the safe area on this root view.
        .background {
            BackgroundView()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $showSetup) {
            CalibrationSheet().environmentObject(vm)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch vm.appearancePreference {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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
