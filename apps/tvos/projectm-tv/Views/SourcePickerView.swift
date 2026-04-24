import SwiftUI
import MusicKit

/// First-run / idle screen for selecting audio source.
struct SourcePickerView: View {
    @Environment(AppState.self) private var appState
    var onSelectSource: ((SourceKind) -> Void)?

    @State private var musicAuthStatus: MusicAuthorization.Status = .notDetermined

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                // Title
                VStack(spacing: 8) {
                    Text("projectM")
                        .font(.largeTitle)
                        .bold()
                    Text("Music Visualizer")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)

                // Source buttons
                VStack(spacing: 20) {
                    Button {
                        Task {
                            let authorized = await MusicKitSource.requestAuthorization()
                            if authorized {
                                onSelectSource?(.appleMusic)
                            } else {
                                musicAuthStatus = .denied
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "music.note")
                            Text("Apple Music")
                        }
                        .frame(maxWidth: 400)
                    }
                    .disabled(musicAuthStatus == .denied || musicAuthStatus == .restricted)

                    Button {
                        onSelectSource?(.localFile)
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            Text("Visualize (Idle)")
                        }
                        .frame(maxWidth: 400)
                    }
                }

                if musicAuthStatus == .denied {
                    Text("Apple Music access denied. Enable in Settings → Privacy → Media & Apple Music.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }

                Spacer()

                // About/Acknowledgements link
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Text("About & Licenses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
        }
        .task {
            musicAuthStatus = MusicAuthorization.currentStatus
        }
    }
}
