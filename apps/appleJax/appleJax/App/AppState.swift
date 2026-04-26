import Foundation
import QuartzCore

enum SourceKind: String {
    case idle
    case appleMusic
    case localFile
    case flapJax
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
    @Published var isPresetBrowserVisible: Bool = false
    @Published var nowPlaying: NowPlayingInfo?
    @Published var currentPresetName: String = "(none)"
    @Published var lastInteractionTime: TimeInterval = CACurrentMediaTime()
    /// True while an iPhone client is actively connected to FlapJaxReceiver.
    /// Drives the QR pairing overlay: visible when no client, hidden when paired.
    @Published var flapJaxClientConnected: Bool = false
    #if DEBUG
    /// Toggled by double-tapping the Siri Remote select button. Shows a corner
    /// box of recent UDP datagram bytes for protocol-level debugging.
    @Published var debugOverlayVisible: Bool = false
    #endif

    // Shared controllers
    let audioController = AudioController()
    let presetLibrary = PresetLibrary()

    /// Set by VisualizerViewController to load a specific preset on demand.
    var onLoadPreset: ((URL) -> Void)?
    @Published var musicKitSource: MusicKitSource?
    @Published var proceduralGenerator: ProceduralPCMGenerator?
    @Published var flapJaxReceiver: FlapJaxReceiver?

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
