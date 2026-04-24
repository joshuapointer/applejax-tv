import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            switch appState.phase {
            case .picker:
                SourcePickerView(onSelectSource: { source in
                    appState.activeSource = source
                    appState.persistSource()

                    // Start the appropriate audio source
                    switch source {
                    case .appleMusic:
                        let musicSource = MusicKitSource(ringBuffer: appState.audioController.ringBuffer)
                        appState.audioController.activate(musicSource)
                    case .localFile, .idle:
                        // Start with procedural audio for idle mode
                        let generator = ProceduralPCMGenerator(ringBuffer: appState.audioController.ringBuffer)
                        generator.start()
                    }

                    appState.phase = .visualizing
                })

            case .visualizing:
                VisualizerContainerView()
                    .ignoresSafeArea()

                // Overlay
                OverlayView()
            }
        }
        .task {
            appState.restore()
        }
    }
}
