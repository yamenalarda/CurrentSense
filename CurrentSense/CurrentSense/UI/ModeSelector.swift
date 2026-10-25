import SwiftUI
import CurrentSenseCore

struct ModeSelector: View {
    let selected: MeasurementMode
    let onSelect: (MeasurementMode) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MeasurementMode.allCases) { mode in
                Button { onSelect(mode) } label: {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(selected == mode ? Color.primary : Color.secondary)
                        .background {
                            if selected == mode {
                                Capsule().fill(.regularMaterial)
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode == .ac ? "AC magnetic field detection" : "DC measurement")
                .accessibilityAddTraits(selected == mode ? .isSelected : [])
                .accessibilityIdentifier("mode.\(mode.rawValue)")
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .animation(.snappy(duration: 0.25), value: selected)
        .frame(maxWidth: 260)
    }
}
