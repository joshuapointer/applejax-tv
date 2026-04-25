import Foundation

/// Manages the bundled preset collection: enumeration, shuffle, history navigation.
final class PresetLibrary {
    private var allPresets: [URL] = []
    private var shuffled: [URL] = []
    private var currentIndex: Int = -1
    private var failedURLs: Set<URL> = []

    /// History ring for previous/next navigation
    private var history: [URL] = []
    private var historyIndex: Int = -1
    private let maxHistory = 64

    init() {
        enumerate()
        shuffle()
    }

    var count: Int { shuffled.count }
    var isEmpty: Bool { shuffled.isEmpty }

    /// Current preset URL, or nil if none loaded.
    var current: URL? {
        guard historyIndex >= 0, historyIndex < history.count else { return nil }
        return history[historyIndex]
    }

    /// Advance to next preset in shuffled order.
    func next() -> URL? {
        guard !shuffled.isEmpty else { return nil }
        currentIndex = (currentIndex + 1) % shuffled.count

        // Skip failed presets
        var attempts = 0
        while failedURLs.contains(shuffled[currentIndex]) && attempts < shuffled.count {
            currentIndex = (currentIndex + 1) % shuffled.count
            attempts += 1
        }

        let url = shuffled[currentIndex]
        pushHistory(url)
        return url
    }

    /// Go back to previous preset in history.
    func previous() -> URL? {
        guard historyIndex > 0 else { return nil }
        historyIndex -= 1
        return history[historyIndex]
    }

    /// Mark a preset as failed (won't be selected again).
    func markFailed(_ url: URL) {
        failedURLs.insert(url)
        logger.info("Preset marked as failed: \(url.lastPathComponent)")
    }

    /// Re-shuffle the playlist.
    func shuffle() {
        shuffled = allPresets.filter { !failedURLs.contains($0) }
        shuffled.shuffle()
        currentIndex = -1
    }

    // MARK: - Private

    private func enumerate() {
        guard let presetsRoot = Bundle.main.resourceURL?.appendingPathComponent("presets") else {
            logger.warning("No presets directory in bundle")
            return
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: presetsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var collected: [URL] = []
        for case let fileURL as URL in enumerator {
            // Skip the "! Transition" directory
            if fileURL.pathComponents.contains("! Transition") { continue }

            let ext = fileURL.pathExtension.lowercased()
            if ext == "milk" || ext == "prjm" {
                collected.append(fileURL)
            }
        }

        allPresets = collected
        logger.info("Enumerated \(collected.count) presets")
    }

    private func pushHistory(_ url: URL) {
        // Trim future history if we navigated back
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(url)
        if history.count > maxHistory {
            history.removeFirst()
        }
        historyIndex = history.count - 1
    }
}
