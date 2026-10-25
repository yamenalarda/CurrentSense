import SwiftUI

enum Palette {
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.0, (0.25, 0.55, 1.00)),   // blue
        (0.4, (0.55, 0.40, 0.95)),   // violet
        (0.7, (1.00, 0.62, 0.30)),   // warm orange
        (1.0, (1.00, 0.27, 0.30))    // red
    ]

    /// Smooth blue -> violet -> warm -> red response for a 0...1 level.
    static func tint(level: Double) -> Color {
        let l = min(1, max(0, level))
        for i in 1..<stops.count where l <= stops[i].0 {
            let (l0, c0) = stops[i - 1], (l1, c1) = stops[i]
            let f = (l - l0) / (l1 - l0)
            return Color(red: c0.0 + (c1.0 - c0.0) * f, green: c0.1 + (c1.1 - c0.1) * f, blue: c0.2 + (c1.2 - c0.2) * f)
        }
        return Color(red: 1, green: 0.27, blue: 0.30)
    }
}

/// Soft colour fields behind the glass so the material has something to refract. Static, rasterised once.
struct BackgroundView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(colors: dark
                           ? [Color(red: 0.03, green: 0.04, blue: 0.09), Color(red: 0.08, green: 0.06, blue: 0.17)]
                           : [Color(red: 0.91, green: 0.95, blue: 1.00), Color(red: 0.96, green: 0.93, blue: 1.00)],
                           startPoint: .top, endPoint: .bottom)
            ZStack {
                Circle().fill(Color.blue.opacity(dark ? 0.35 : 0.26)).frame(width: 320).offset(x: -120, y: -230)
                Circle().fill(Color.purple.opacity(dark ? 0.32 : 0.20)).frame(width: 300).offset(x: 150, y: 40)
                Circle().fill(Color.orange.opacity(dark ? 0.16 : 0.16)).frame(width: 260).offset(x: -70, y: 300)
            }
            .blur(radius: 80)
            .drawingGroup()
        }
        .ignoresSafeArea()
    }
}
