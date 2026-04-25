import SwiftUI

/// HUD overlay showing preset name, now-playing info, and lock state.
/// Auto-hides after 5 seconds of no interaction.
struct OverlayView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isOverlayVisible {
            VStack(alignment: .leading, spacing: 12) {
                // Preset info
                HStack(spacing: 8) {
                    if appState.isLocked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(appState.currentPresetName)
                        .font(.headline)
                        .lineLimit(1)
                }

                // Source label
                Text(sourceLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Controls hint
                HStack(spacing: 16) {
                    Label("Browse", systemImage: "chevron.up")
                    Label("Shuffle", systemImage: "chevron.down")
                    Label("←/→ Skip", systemImage: "arrow.left.arrow.right")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                // Now playing
                if let np = appState.nowPlaying, !np.title.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(np.title)
                            .font(.body)
                            .lineLimit(1)
                        if !np.artist.isEmpty {
                            Text(np.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !np.album.isEmpty {
                            Text(np.album)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 500, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(40)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.3), value: appState.isOverlayVisible)
        }
    }

    private var sourceLabel: String {
        switch appState.activeSource {
        case .idle: return "Idle"
        case .appleMusic: return "Apple Music"
        case .localFile: return "Local File"
        }
    }
}
