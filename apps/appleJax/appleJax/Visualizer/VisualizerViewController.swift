import UIKit
import Metal
import QuartzCore
import OpenGLES

final class VisualizerViewController: UIViewController {
    // Injected from outside
    var appState: AppState?
    var audioController: AudioController?
    var presetLibrary: PresetLibrary?

    private var renderEngine: RenderEngine?
    private var metalLayer: CAMetalLayer?

    private let inputHandler = RemoteInputHandler()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupRendering()
        setupInput()

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Setup

    private func setupRendering() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("Metal not available on this device")
            showFatalError("Metal not available")
            return
        }

        let scale = UIScreen.main.nativeScale
        let pixelWidth = Int(view.bounds.width * scale)
        let pixelHeight = Int(view.bounds.height * scale)

        // Use CAMetalLayer directly — nextDrawable() is explicitly safe from any thread,
        // allowing the full render pipeline to run on the background render thread.
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsScale = scale
        layer.frame = view.bounds
        layer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
        // 3 in-flight drawables match the GL→Metal triple buffer in GLMetalBridge,
        // so the GPU never blocks waiting for a free drawable at 60 fps.
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
        view.layer.addSublayer(layer)
        metalLayer = layer

        guard let engine = RenderEngine(device: device, metalLayer: layer,
                                        pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            logger.error("Failed to create RenderEngine")
            showFatalError("Rendering engine failed to start")
            return
        }
        engine.audioController = audioController
        renderEngine = engine

        // Queue the first preset before starting — render thread picks it up on its first frame,
        // avoiding any race between thread startup and the first preset load.
        if let lib = presetLibrary, let url = lib.next() {
            engine.requestPreset(url, smooth: false)
            // Defer the @Published mutation: setupRendering can be called inside the SwiftUI
            // view-update cycle (UIViewControllerRepresentable host), and mutating ObservableObject
            // state synchronously there triggers "Publishing changes from within view updates is not
            // allowed". Hopping to the next runloop tick avoids the warning without losing the update.
            let presetName = url.deletingPathExtension().lastPathComponent
            DispatchQueue.main.async { [weak self] in
                self?.appState?.currentPresetName = presetName
            }
        }

        engine.start()
        renderLogger.info("RenderEngine started at \(pixelWidth)x\(pixelHeight)")
    }

    // MARK: - Layout

    private var lastPixelSize: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let metalLayer else { return }
        let scale = UIScreen.main.nativeScale
        let pw = Int(view.bounds.width * scale)
        let ph = Int(view.bounds.height * scale)
        let newSize = CGSize(width: pw, height: ph)
        guard newSize != lastPixelSize else { return }
        lastPixelSize = newSize

        // Only update the CALayer frame (position/geometry) on the main thread.
        // drawableSize is updated on the render thread via requestResize to avoid
        // mutating it while nextDrawable() is in flight on the render thread.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        CATransaction.commit()

        renderEngine?.requestResize(pixelWidth: pw, pixelHeight: ph)
    }

    // MARK: - Input

    private func setupInput() {
        inputHandler.onCommand = { [weak self] command in
            self?.handleCommand(command)
        }
        appState?.onLoadPreset = { [weak self] url in
            self?.loadSpecificPreset(url)
        }
    }

    private func loadSpecificPreset(_ url: URL) {
        presetLibrary?.jumpTo(url)
        renderEngine?.requestPreset(url, smooth: true)
        appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
        appState?.isPresetBrowserVisible = false
        inputHandler.setPresetBrowserVisible(false)
    }

    private func handleCommand(_ command: InputCommand) {
        appState?.recordInteraction()

        switch command {
        case .nextPreset:
            if let url = presetLibrary?.next() {
                renderEngine?.requestPreset(url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .previousPreset:
            if let url = presetLibrary?.previous() {
                renderEngine?.requestPreset(url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .toggleLock:
            if let state = appState {
                state.isLocked.toggle()
                renderEngine?.requestSetLocked(state.isLocked)
            }
        case .showOverlay:
            appState?.isOverlayVisible = true
            inputHandler.setOverlayVisible(true)
            startOverlayAutoHide()
        case .hideOverlay:
            appState?.isOverlayVisible = false
            inputHandler.setOverlayVisible(false)
        case .togglePlayPause:
            audioController?.togglePlayPause()
        case .shufflePresets:
            presetLibrary?.shuffle()
            if let url = presetLibrary?.next() {
                renderEngine?.requestPreset(url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .showPresetBrowser:
            appState?.isPresetBrowserVisible = true
            inputHandler.setPresetBrowserVisible(true)
        case .hidePresetBrowser:
            appState?.isPresetBrowserVisible = false
            inputHandler.setPresetBrowserVisible(false)
        case .toggleDebugOverlay:
            #if DEBUG
            appState?.debugOverlayVisible.toggle()
            #endif
        }
    }

    private var overlayHideTask: Task<Void, Never>?

    private func startOverlayAutoHide() {
        overlayHideTask?.cancel()
        overlayHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.appState?.isOverlayVisible = false
            self?.inputHandler.setOverlayVisible(false)
        }
    }

    // MARK: - Press handling (Siri Remote)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if inputHandler.handlePress(press, phase: .began) {
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
    }

    // MARK: - Lifecycle

    @objc private func didEnterBackground() {
        renderEngine?.pauseRendering()
    }

    @objc private func willEnterForeground() {
        renderEngine?.resumeRendering()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        renderEngine?.stop()
    }

    private func showFatalError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 36)
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}
