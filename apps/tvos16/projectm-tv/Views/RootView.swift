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
                    case .appleJax:
                        appState.proceduralGenerator?.stop()
                        appState.proceduralGenerator = nil
                        let receiver = AppleJaxReceiver(ringBuffer: appState.audioController.ringBuffer)
                        do {
                            try receiver.start()
                            appState.appleJaxReceiver = receiver
                            appState.activeSource = .appleJax
                            appState.phase = .visualizing
                        } catch {
                            audioLogger.error("AppleJax receiver start failed: \(error.localizedDescription)")
                        }
                    case .localFile, .idle:
                        appState.appleJaxReceiver?.stop()
                        appState.appleJaxReceiver = nil
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

                if appState.isPresetBrowserVisible {
                    PresetBrowserView()
                        .ignoresSafeArea()
                }
            }
        }
        .task {
            appState.restore()
        }
    }
}
