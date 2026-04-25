import Foundation
import Observation

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

@Observable
final class AppState {
    enum Phase {
        case picker
        case musicBrowser
        case visualizing
    }

    var phase: Phase = .picker
    var activeSource: SourceKind = .idle
    var isLocked: Bool = false
    var isOverlayVisible: Bool = false
    var nowPlaying: NowPlayingInfo?
    var currentPresetName: String = "(none)"
    var lastInteractionTime: TimeInterval = CACurrentMediaTime()

    // Shared controllers
    let audioController = AudioController()
    let presetLibrary = PresetLibrary()
    var musicKitSource: MusicKitSource?
    var proceduralGenerator: ProceduralPCMGenerator?

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
