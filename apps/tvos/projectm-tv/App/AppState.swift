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

    var phase: Phase = .visualizing  // Skip picker for now, go straight to visualizer
    var activeSource: SourceKind = .idle
    var isLocked: Bool = false
    var isOverlayVisible: Bool = false
    var nowPlaying: NowPlayingInfo?
    var currentPresetName: String = "(none)"
}
