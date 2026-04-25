import Foundation

enum SourceKind: String {
    case idle
    case appleMusic
    case localFile
}

struct NowPlayingInfo {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var bpm: Double?
}

final class AppState: ObservableObject {
    enum Phase {
        case picker
        case musicBrowser
        case visualizing
    }

    @Published var phase: Phase = .picker
    @Published var activeSource: SourceKind = .idle
    @Published var isLocked: Bool = false
    @Published var isOverlayVisible: Bool = false
    @Published var nowPlaying: NowPlayingInfo?
    @Published var currentPresetName: String = "(none)"
    @Published var lastInteractionTime: TimeInterval = CACurrentMediaTime()

    // Shared controllers
    let audioController = AudioController()
    let presetLibrary = PresetLibrary()
    @Published var musicKitSource: MusicKitSource?
    @Published var proceduralGenerator: ProceduralPCMGenerator?

    func recordInteraction() {
        lastInteractionTime = CACurrentMediaTime()
    }

    /// Persist source choice to UserDefaults
    func persistSource() {
        UserDefaults.standard.set(activeSource.rawValue, forKey: "lastSourceMode")
    }

    /// Restore persisted state. Always starts at picker — user must choose.
    func restore() {
        // Clear any stale defaults so we always show the picker
        phase = .picker
    }
}
