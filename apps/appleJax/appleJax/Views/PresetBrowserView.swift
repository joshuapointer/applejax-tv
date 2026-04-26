import SwiftUI

/// Full-screen preset browser shown over the visualizer.
/// Up arrow or Menu to dismiss. Select a preset to load it immediately.
struct PresetBrowserView: View {
    @EnvironmentObject private var appState: AppState

    @State private var expandedCategory: String? = nil
    @State private var searchText: String = ""

    private var categories: [(name: String, presets: [URL])] {
        let all = appState.presetLibrary.categories
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.compactMap { cat in
            let filtered = cat.presets.filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains(q) }
            return filtered.isEmpty ? nil : (name: cat.name, presets: filtered)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(categories, id: \.name) { category in
                            Section {
                                if expandedCategory == category.name {
                                    ForEach(category.presets, id: \.self) { url in
                                        presetRow(url: url)
                                    }
                                }
                            } header: {
                                categoryHeader(category)
                            }
                        }
                    }
                    .padding(.horizontal, 60)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .animation(.easeInOut(duration: 0.25), value: appState.isPresetBrowserVisible)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Presets")
                    .font(.title2).bold()
                Text("\(appState.presetLibrary.count) presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appState.onLoadPreset?(appState.presetLibrary.categories.randomElement()?.presets.randomElement() ?? URL(fileURLWithPath: ""))
                appState.presetLibrary.shuffle()
            } label: {
                Label("Shuffle All", systemImage: "shuffle")
            }

            Button {
                appState.isPresetBrowserVisible = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 24)
    }

    private func categoryHeader(_ category: (name: String, presets: [URL])) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedCategory = expandedCategory == category.name ? nil : category.name
            }
        } label: {
            HStack {
                Image(systemName: expandedCategory == category.name ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(category.name)
                    .font(.headline)
                Spacer()
                Text("\(category.presets.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presetRow(url: URL) -> some View {
        let name = url.deletingPathExtension().lastPathComponent
        let isCurrent = name == appState.currentPresetName

        return Button {
            appState.onLoadPreset?(url)
        } label: {
            HStack {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                } else {
                    Spacer().frame(width: 16)
                }
                Text(name)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.leading, 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
