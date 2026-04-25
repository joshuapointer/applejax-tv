import UIKit
import Metal
import MetalKit
import OpenGLES

final class VisualizerViewController: UIViewController, MTKViewDelegate {
    private var metalDevice: MTLDevice?
    private var mtkView: MTKView?
    private var bridge: GLMetalBridge?
    private var metalRenderer: MetalRenderer?
    private var projectMRenderer: ProjectMRenderer?
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
        setupMetal()
        setupInput()
        loadFirstPreset()

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Setup

    private func setupMetal() {
        // 1. Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("Metal is not available on this device")
            showFatalError("Metal not available")
            return
        }
        self.metalDevice = device

        // 2. GL↔Metal bridge (creates EAGLContext + texture caches)
        guard let glMetalBridge = GLMetalBridge(device: device) else {
            logger.error("Failed to create GLMetalBridge")
            showFatalError("GL/Metal bridge failed")
            return
        }
        self.bridge = glMetalBridge

        // 3. Metal renderer (pipeline state + command queue)
        guard let mtlRenderer = MetalRenderer(device: device) else {
            logger.error("Failed to create MetalRenderer")
            showFatalError("Metal renderer failed")
            return
        }
        self.metalRenderer = mtlRenderer

        // 4. projectM renderer (requires GL context current)
        EAGLContext.setCurrent(glMetalBridge.glContext)

        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        guard let pmRenderer = ProjectMRenderer(viewportSize: view.bounds.size, scale: scale) else {
            logger.error("Failed to create ProjectMRenderer")
            showFatalError("Rendering engine failed to start")
            return
        }
        self.projectMRenderer = pmRenderer

        // 5. MTKView (presentation surface)
        let metalView = MTKView(frame: view.bounds, device: device)
        metalView.delegate = self
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.autoResizeDrawable = true
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.contentScaleFactor = scale
        view.addSubview(metalView)
        self.mtkView = metalView

        // 6. Initial resize of the bridge to match drawable
        let drawableSize = metalView.drawableSize
        glMetalBridge.resize(width: Int(drawableSize.width), height: Int(drawableSize.height))
        pmRenderer.setViewport(width: Int(drawableSize.width), height: Int(drawableSize.height))

        // 7. Allocate PCM drain buffer
        pcmDrainBuffer = .allocate(capacity: maxSamples * 2)

        isSetUp = true
        renderLogger.info("Metal setup complete, MTKView rendering at \(Int(drawableSize.width))x\(Int(drawableSize.height))")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard isSetUp else { return }
        let w = Int(size.width)
        let h = Int(size.height)

        EAGLContext.setCurrent(bridge?.glContext)
        bridge?.resize(width: w, height: h)
        projectMRenderer?.setViewport(width: w, height: h)
        renderLogger.info("Drawable resized to \(w)x\(h)")
    }

    func draw(in view: MTKView) {
        guard isSetUp,
              let bridge,
              let projectMRenderer,
              let metalRenderer else { return }

        // 1. Make GL context current
        EAGLContext.setCurrent(bridge.glContext)

        // 2. Get next framebuffer from triple-buffer pool
        guard let (fbo, pixelBuffer) = bridge.nextFramebuffer() else { return }

        // 3. Drain PCM from ring buffer into projectM
        if let ringBuffer = audioController?.ringBuffer,
           let drainBuf = pcmDrainBuffer {
            let framesRead = ringBuffer.read(into: drainBuf, maxFrames: maxSamples)
            if framesRead > 0 {
                projectMRenderer.addPCM(drainBuf, frameCount: UInt32(framesRead), channels: 2)
            }
        }

        // 4. GL render (projectM writes to the CVPixelBuffer-backed FBO)
        projectMRenderer.renderFrame(fbo: fbo)

        // 5. Flush GL — submit commands, don't wait (Metal will read asynchronously)
        bridge.flush()

        // 6. Get the GL output as a Metal texture (zero-copy)
        guard let texture = bridge.metalTexture(from: pixelBuffer) else { return }

        // 7. Metal blit to drawable
        metalRenderer.render(texture: texture, in: view)
    }

    // MARK: - Presets

    private func loadFirstPreset() {
        guard let lib = presetLibrary, let url = lib.next() else { return }
        projectMRenderer?.loadPreset(at: url, smooth: false)
        appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
    }

    private func loadSpecificPreset(_ url: URL) {
        presetLibrary?.jumpTo(url)
        projectMRenderer?.loadPreset(at: url, smooth: true)
        appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
        appState?.isPresetBrowserVisible = false
        inputHandler.setPresetBrowserVisible(false)
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

    private func handleCommand(_ command: InputCommand) {
        appState?.recordInteraction()

        switch command {
        case .nextPreset:
            if let url = presetLibrary?.next() {
                projectMRenderer?.loadPreset(at: url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .previousPreset:
            if let url = presetLibrary?.previous() {
                projectMRenderer?.loadPreset(at: url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .toggleLock:
            if let state = appState {
                state.isLocked.toggle()
                projectMRenderer?.setLocked(state.isLocked)
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
                projectMRenderer?.loadPreset(at: url, smooth: true)
                appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
            }
        case .showPresetBrowser:
            appState?.isPresetBrowserVisible = true
            inputHandler.setPresetBrowserVisible(true)
        case .hidePresetBrowser:
            appState?.isPresetBrowserVisible = false
            inputHandler.setPresetBrowserVisible(false)
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
        mtkView?.isPaused = true
        if let ctx = bridge?.glContext {
            EAGLContext.setCurrent(ctx)
            glFinish()
        }
        bridge?.flushCaches()
    }

    @objc private func willEnterForeground() {
        if let ctx = bridge?.glContext {
            EAGLContext.setCurrent(ctx)
        }
        mtkView?.isPaused = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        mtkView?.isPaused = true
        mtkView?.delegate = nil
        pcmDrainBuffer?.deallocate()
        pcmDrainBuffer = nil
        isSetUp = false
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
