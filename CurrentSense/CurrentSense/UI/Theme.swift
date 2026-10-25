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

/// True black, edge-to-edge background. The glass disc supplies the only colour accent.
struct BackgroundView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .dark ? Color.black : Color.white)
            .ignoresSafeArea(.all)
            .accessibilityHidden(true)
    }
}
