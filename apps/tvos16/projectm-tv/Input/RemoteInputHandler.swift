import UIKit
import GameController

/// Handles Siri Remote input and translates press events into app commands.
/// Installed as pressesBegan/pressesEnded override on VisualizerViewController.
final class RemoteInputHandler {
    var onCommand: ((InputCommand) -> Void)?

    private var lastPresetCommandTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.1  // 100ms
    private var isOverlayVisible: Bool = false
    private var isPresetBrowserVisible: Bool = false

    #if DEBUG
    /// Single-tap select fires `toggleLock` after the double-tap window expires.
    /// A second tap within the window cancels the pending work and fires
    /// `toggleDebugOverlay` instead. The window is short enough to not feel laggy
    /// for the lock toggle, but long enough to catch a typical double-tap.
    private let selectDoubleTapWindow: TimeInterval = 0.35
    private var pendingSelectWork: DispatchWorkItem?
    #endif

    func setOverlayVisible(_ visible: Bool) {
        isOverlayVisible = visible
    }

    func setPresetBrowserVisible(_ visible: Bool) {
        isPresetBrowserVisible = visible
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
        case .upArrow:
            if isPresetBrowserVisible {
                onCommand?(.hidePresetBrowser)
            } else {
                onCommand?(.showPresetBrowser)
            }
            return true
        case .downArrow:
            return emitDebounced(.shufflePresets)
        case .select:
            #if DEBUG
            handleSelectPress()
            #else
            onCommand?(.toggleLock)
            #endif
            return true
        case .menu:
            if isPresetBrowserVisible {
                onCommand?(.hidePresetBrowser)
                return true
            }
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

    #if DEBUG
    /// Defers the single-tap `toggleLock` so a second tap within the window can
    /// upgrade it to `toggleDebugOverlay`. A bit of lag on lock-toggle is the
    /// price of the gesture; release builds keep the immediate behavior.
    private func handleSelectPress() {
        if let pending = pendingSelectWork {
            pending.cancel()
            pendingSelectWork = nil
            onCommand?(.toggleDebugOverlay)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSelectWork = nil
            self.onCommand?(.toggleLock)
        }
        pendingSelectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + selectDoubleTapWindow, execute: work)
    }
    #endif
}
