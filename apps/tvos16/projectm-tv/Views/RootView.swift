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

            if appState.appleJaxClientConnected {
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
        .animation(.easeInOut(duration: 0.25), value: appState.appleJaxClientConnected)
        .task {
            startAppleJaxIfNeeded()
        }
    }

    /// Starts the AppleJax receiver on first appearance. The QR pairing overlay covers
    /// the (silent) visualizer until an iPhone client connects; after that, real PCM
    /// from the iPhone drives projectM. The receiver's onClientChange drives the overlay
    /// via @Published state on AppState.
    private func startAppleJaxIfNeeded() {
        guard appState.appleJaxReceiver == nil else { return }
        let receiver = AppleJaxReceiver(ringBuffer: appState.audioController.ringBuffer)
        receiver.onClientChange = { [weak appState = self.appState] connected in
            DispatchQueue.main.async {
                appState?.appleJaxClientConnected = connected
                appState?.activeSource = connected ? .appleJax : .idle
            }
        }
        do {
            try receiver.start()
            appState.appleJaxReceiver = receiver
            appState.phase = .visualizing
        } catch {
            audioLogger.error("AppleJax receiver start failed: \(error.localizedDescription)")
        }
    }
}
