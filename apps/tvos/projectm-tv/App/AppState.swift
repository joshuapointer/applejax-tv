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

    func recordInteraction() {
        lastInteractionTime = CACurrentMediaTime()
    }

    /// Persist source choice to UserDefaults
    func persistSource() {
        UserDefaults.standard.set(activeSource.rawValue, forKey: "lastSourceMode")
    }

    /// Restore persisted state
    func restore() {
        if let raw = UserDefaults.standard.string(forKey: "lastSourceMode"),
           let source = SourceKind(rawValue: raw), source != .idle {
            activeSource = source
            phase = .visualizing
        }
    }
}
