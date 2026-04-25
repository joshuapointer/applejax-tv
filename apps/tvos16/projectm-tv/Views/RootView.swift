import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            switch appState.phase {
            case .picker:
                SourcePickerView(onSelectSource: { source in
                    switch source {
                    case .appleMusic:
                        appState.phase = .musicBrowser
                    case .localFile, .idle:
                        // Start procedural beat generator so the visualizer reacts
                        let gen = ProceduralPCMGenerator(ringBuffer: appState.audioController.ringBuffer)
                        gen.start()
                        appState.proceduralGenerator = gen  // hold reference
                        appState.activeSource = source
                        appState.phase = .visualizing
                    }
                })

            case .musicBrowser:
                MusicBrowserView()

            case .visualizing:
                VisualizerContainerView()
                    .ignoresSafeArea()

                OverlayView()
            }
        }
        .task {
            appState.restore()
        }
    }
}
