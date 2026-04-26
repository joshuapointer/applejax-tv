import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            // Visualizer is always live in the background. It renders silence (or
            // the procedural placeholder) until the iPhone client starts streaming;
            // the QR overlay covers it until that happens.
            VisualizerContainerView()
                .ignoresSafeArea()

            if appState.flapJaxClientConnected {
                OverlayView()
                if appState.isPresetBrowserVisible {
                    PresetBrowserView()
                        .ignoresSafeArea()
                }
            } else {
                WaitingForClientView()
                    .transition(.opacity)
            }

            #if DEBUG
            if appState.debugOverlayVisible {
                VStack {
                    HStack {
                        Spacer()
                        DebugOverlayView()
                            .padding(.top, 60)
                            .padding(.trailing, 60)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.25), value: appState.flapJaxClientConnected)
        .task {
            startFlapJaxIfNeeded()
        }
    }

    /// Starts the FlapJax receiver on first appearance. The QR pairing overlay covers
    /// the (silent) visualizer until an iPhone client connects; after that, real PCM
    /// from the iPhone drives projectM. The receiver's onClientChange drives the overlay
    /// via @Published state on AppState.
    private func startFlapJaxIfNeeded() {
        guard appState.flapJaxReceiver == nil else { return }
        let receiver = FlapJaxReceiver(ringBuffer: appState.audioController.ringBuffer)
        receiver.onClientChange = { [weak appState = self.appState] connected in
            DispatchQueue.main.async {
                appState?.flapJaxClientConnected = connected
                appState?.activeSource = connected ? .flapJax : .idle
            }
        }
        do {
            try receiver.start()
            appState.flapJaxReceiver = receiver
            appState.phase = .visualizing
        } catch {
            audioLogger.error("FlapJax receiver start failed: \(error.localizedDescription)")
        }
    }
}
