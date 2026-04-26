import Foundation

/// Commands triggered by Siri Remote input.
enum InputCommand {
    case previousPreset
    case nextPreset
    case toggleLock
    case showOverlay
    case hideOverlay
    case togglePlayPause
    case shufflePresets
    case showPresetBrowser
    case hidePresetBrowser
    /// Toggles the on-screen DEBUG-only raw-UDP-data overlay. Bound to a double-click
    /// of the Siri Remote select (TV center) button.
    case toggleDebugOverlay
}
