import UIKit
import GameController

/// Handles Siri Remote input and translates press events into app commands.
/// Installed as pressesBegan/pressesEnded override on VisualizerViewController.
final class RemoteInputHandler {
    var onCommand: ((InputCommand) -> Void)?

    private var lastPresetCommandTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.1  // 100ms
    private var isOverlayVisible: Bool = false

    func setOverlayVisible(_ visible: Bool) {
        isOverlayVisible = visible
    }

    /// Process a press event. Returns true if the event was handled (don't call super).
    func handlePress(_ press: UIPress, phase: UIPress.Phase) -> Bool {
        guard phase == .began, let type = press.type as UIPress.PressType? else {
            return false
        }

        switch type {
        case .leftArrow:
            return emitDebounced(.previousPreset)
        case .rightArrow:
            return emitDebounced(.nextPreset)
        case .select:
            onCommand?(.toggleLock)
            return true
        case .menu:
            if isOverlayVisible {
                onCommand?(.hideOverlay)
            } else {
                onCommand?(.showOverlay)
            }
            return true
        case .playPause:
            onCommand?(.togglePlayPause)
            return true
        default:
            return false
        }
    }

    private func emitDebounced(_ command: InputCommand) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastPresetCommandTime < debounceInterval {
            return true  // swallow the event
        }
        lastPresetCommandTime = now
        onCommand?(command)
        return true
    }
}
