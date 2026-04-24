import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .picker:
            Text("Source Picker (TODO)")
                .font(.headline)
        case .visualizing:
            VisualizerContainerView()
                .ignoresSafeArea()
        }
    }
}
