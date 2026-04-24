import UIKit
import GLKit
import OpenGLES

final class VisualizerViewController: UIViewController, GLKViewDelegate {
    private var glContext: EAGLContext?
    private var glkView: GLKView?
    private var displayLink: DisplayLinkDriver?
    private var renderer: ProjectMRenderer?
    private var isSetUp = false

    // Injected from outside
    var appState: AppState?
    var audioController: AudioController?
    var presetLibrary: PresetLibrary?

    // Input handling
    private let inputHandler = RemoteInputHandler()

    // PCM drain buffer (reused each frame to avoid allocation)
    private var pcmDrainBuffer: UnsafeMutablePointer<Float>?
    private let maxSamples: Int = 576  // projectM default max_samples

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupGL()
        setupInput()
        loadFirstPreset()

        // Background/foreground observers
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    private func setupGL() {
        guard let context = EAGLContextFactory.makeContext() else {
            logger.error("Cannot create EAGL context — fatal")
            showFatalError("OpenGL ES 3.0 not available")
            return
        }
        glContext = context
        EAGLContext.setCurrent(context)

        let glView = GLKView(frame: view.bounds, context: context)
        glView.delegate = self
        glView.drawableColorFormat = .RGBA8888
        glView.drawableDepthFormat = .format24
        glView.drawableStencilFormat = .format8
        glView.drawableMultisample = .multisampleNone
        glView.enableSetNeedsDisplay = true
        glView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glView.contentScaleFactor = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        view.addSubview(glView)
        self.glkView = glView

        let scale = glView.contentScaleFactor
        guard let pmRenderer = ProjectMRenderer(viewportSize: view.bounds.size, scale: scale) else {
            logger.error("Failed to create ProjectMRenderer")
            showFatalError("Rendering engine failed to start")
            return
        }
        self.renderer = pmRenderer
        isSetUp = true

        // Allocate drain buffer
        pcmDrainBuffer = .allocate(capacity: maxSamples * 2)

        // Start display link with audio drain
        let driver = DisplayLinkDriver()
        driver.start { [weak self] in
            self?.tick()
        }
        self.displayLink = driver

        renderLogger.info("GL setup complete, display link started")
    }

    private func tick() {
        guard isSetUp else { return }

        // Drain PCM from ring buffer into projectM
        if let ringBuffer = audioController?.ringBuffer,
           let drainBuf = pcmDrainBuffer {
            let framesRead = ringBuffer.read(into: drainBuf, maxFrames: maxSamples)
            if framesRead > 0 {
                renderer?.addPCM(drainBuf, frameCount: UInt32(framesRead), channels: 2)
            }
        }

        glkView?.setNeedsDisplay()
    }

    private func loadFirstPreset() {
        guard let lib = presetLibrary, let url = lib.next() else { return }
        renderer?.loadPreset(at: url, smooth: false)
        appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Input

    private func setupInput() {
        inputHandler.onCommand = { [weak self] command in
            self?.handleCommand(command)
        }
    }

    private func handleCommand(_ command: InputCommand) {
        appState?.recordInteraction()

        switch command {
        case .nextPreset:
            if let url = presetLibrary?.next() {
                renderer?.loadPreset(at: url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .previousPreset:
            if let url = presetLibrary?.previous() {
                renderer?.loadPreset(at: url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .toggleLock:
            if let state = appState {
                state.isLocked.toggle()
                renderer?.setLocked(state.isLocked)
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

    // MARK: - GLKViewDelegate

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isSetUp else { return }
        let scale = glkView?.contentScaleFactor ?? 1.0
        renderer?.setViewport(size: view.bounds.size, scale: scale)
    }

    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard isSetUp else { return }
        var currentFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &currentFBO)
        renderer?.renderFrame(intoFBO: currentFBO)
    }

    // MARK: - Lifecycle

    @objc private func didEnterBackground() {
        displayLink?.pause()
        audioController?.togglePlayPause()  // pause
        if let ctx = glContext {
            EAGLContext.setCurrent(ctx)
            glFinish()
        }
    }

    @objc private func willEnterForeground() {
        if let ctx = glContext {
            EAGLContext.setCurrent(ctx)
        }
        displayLink?.resume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.stop()
        pcmDrainBuffer?.deallocate()
        pcmDrainBuffer = nil
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
