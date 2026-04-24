import SwiftUI

struct VisualizerContainerView: UIViewControllerRepresentable {
    @Environment(AppState.self) private var appState

    func makeUIViewController(context: Context) -> VisualizerViewController {
        let vc = VisualizerViewController()
        vc.appState = appState
        vc.audioController = appState.audioController
        vc.presetLibrary = appState.presetLibrary
        return vc
    }

    func updateUIViewController(_ uiViewController: VisualizerViewController, context: Context) {
        // State updates flow through AppState directly
    }
}
