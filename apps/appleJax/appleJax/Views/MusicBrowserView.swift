import SwiftUI
import MusicKit

/// Browse and pick songs from the user's Apple Music library.
struct MusicBrowserView: View {
    @EnvironmentObject private var appState: AppState

    @State private var recentSongs: [Song] = []
    @State private var librarySongs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    ProgressView("Loading your music…")
                        .padding()
                } else if let error = errorMessage {
                    VStack(spacing: 24) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.yellow)
                        Text("Can't Access Apple Music")
                            .font(.title3)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 500)

                        Text("To use Apple Music, the app needs to be signed with a developer certificate that has the MusicKit capability enabled in the Apple Developer portal.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 500)

                        Button("Start Visualizer with Beat Generator") {
                            startWithoutSong()
                        }
                        .padding(.top, 8)
                    }
                    .padding(40)
                } else {
                    TabView(selection: $selectedTab) {
                        songList(songs: recentSongs, emptyText: "No recently played songs")
                            .tabItem { Label("Recent", systemImage: "clock") }
                            .tag(0)

                        songList(songs: librarySongs, emptyText: "No songs in library")
                            .tabItem { Label("Library", systemImage: "music.note.list") }
                            .tag(1)
                    }
                }
            }
            .navigationTitle("Pick a Song")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        appState.phase = .picker
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skip — Just Visualize") {
                        startWithoutSong()
                    }
                }
            }
        }
        .task {
            await loadMusic()
        }
    }

    private func songList(songs: [Song], emptyText: String) -> some View {
        Group {
            if songs.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(songs, id: \.id) { song in
                    Button {
                        playSong(song)
                    } label: {
                        HStack(spacing: 16) {
                            if let artwork = song.artwork {
                                ArtworkImage(artwork, width: 60, height: 60)
                                    .cornerRadius(6)
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                                    .frame(width: 60, height: 60)
                                    .overlay {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(song.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let album = song.albumTitle {
                                    Text(album)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadMusic() async {
        isLoading = true
        do {
            async let recent = MusicKitSource.fetchRecentlyPlayed()
            async let library = MusicKitSource.fetchLibrarySongs(limit: 100)

            let (r, l) = try await (recent, library)
            recentSongs = r
            librarySongs = l
            isLoading = false
        } catch {
            errorMessage = "Couldn't load your music library.\n\(error.localizedDescription)"
            isLoading = false
        }
    }

    private func playSong(_ song: Song) {
        let source = MusicKitSource(ringBuffer: appState.audioController.ringBuffer)
        appState.musicKitSource = source
        appState.audioController.activate(source)
        appState.activeSource = .appleMusic
        appState.persistSource()

        Task {
            do {
                try await source.play(song: song)
                appState.nowPlaying = source.nowPlaying
            } catch {
                audioLogger.error("Failed to play song: \(error.localizedDescription)")
            }
        }

        appState.phase = .visualizing
    }

    private func startWithoutSong() {
        // Use procedural beat generator (no MusicKit needed)
        let gen = ProceduralPCMGenerator(ringBuffer: appState.audioController.ringBuffer)
        gen.start()
        appState.proceduralGenerator = gen
        appState.activeSource = .idle
        appState.phase = .visualizing
    }
}
