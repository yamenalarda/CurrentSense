import SwiftUI

@main
struct CurrentSenseApp: App {
    @StateObject private var viewModel = MeasurementViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { _, newPhase in viewModel.scenePhaseChanged(newPhase) }
        }
    }
}
