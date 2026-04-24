import SwiftUI

struct VisualizerContainerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> VisualizerViewController {
        return VisualizerViewController()
    }

    func updateUIViewController(_ uiViewController: VisualizerViewController, context: Context) {
        // No updates needed from SwiftUI side
    }
}
