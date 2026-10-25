import SwiftUI
import CurrentSenseCore

struct ReadingsPanel: View {
    let presentation: ReadingsPresentation
    let mode: MeasurementMode
    @Binding var audioEnabled: Bool
    let onSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(presentation.header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(presentation.isLive ? Color.primary : Color.secondary)
                    .accessibilityIdentifier("readings.header")
                Spacer()
                if mode == .dc {
                    Button("Current setup", action: onSetup)
                        .font(.footnote)
                        .accessibilityIdentifier("setup.button")
                }
                Button { audioEnabled.toggle() } label: {
                    Image(systemName: audioEnabled ? "speaker.wave.2" : "speaker.slash")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .fixedSize()
                .accessibilityLabel("Audio feedback")
                .accessibilityValue(audioEnabled ? "On" : "Off")
                .accessibilityIdentifier("audio.toggle")
            }
            ForEach(presentation.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 6)
                    Text(row.value)
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .multilineTextAlignment(.trailing)
                        .layoutPriority(1)
                        .opacity(presentation.isLive ? 1 : 0.65)   // last results look different from live ones
                        .accessibilityIdentifier("reading.\(row.id).value")
                }
            }
            Text(presentation.status)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("readings.status")
            if let d = presentation.disclaimer {
                Text(d).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("readings.disclaimer")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    }
}
