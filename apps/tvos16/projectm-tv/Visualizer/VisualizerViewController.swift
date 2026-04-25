import UIKit
import Metal
import MetalKit
import OpenGLES

/// Owns the projectM render pipeline.
///
/// Pipeline:
///   1. `RenderLoop` (background thread, `CADisplayLink`) drives `drawFrame()`.
///   2. Frame-in-flight semaphore (count = `bufferCount`) bounds CPU/GPU lag.
///   3. projectM renders into the next CVPixelBuffer-backed FBO via `GLMetalBridge`.
///   4. `MetalRenderer` upscales (MetalFX) or blits (fallback) to the MTKView drawable.
///   5. `PerformanceMonitor` adapts internal render resolution to hold 60 fps.
///
/// **Threading.** All rendering happens on the render thread. EAGLContext is
/// bound there once and never switched. Cross-thread input commands are
/// routed through `RenderLoop.enqueue(_:)` to land on the render thread.
final class VisualizerViewController: UIViewController {
    // Injected from outside (main thread)
    var appState: AppState?
    var audioController: AudioController?
    var presetLibrary: PresetLibrary?

    // Pipeline pieces (touched only from render thread once setup completes)
    private var metalDevice: MTLDevice?
    private var mtkView: MTKView?
    private var bridge: GLMetalBridge?
    private var metalRenderer: MetalRenderer?
    private var projectMRenderer: ProjectMRenderer?
    private let perfMonitor = PerformanceMonitor(targetFps: 60.0)
    private let renderLoop = RenderLoop(preferredFps: 60)

    // PCM drain buffer (reused; sized for ~48 kHz @ 60 fps with headroom)
    private var pcmDrainBuffer: UnsafeMutablePointer<Float>?
    private let pcmDrainCapacityFrames: Int = 2048  // = ~42 ms @ 48 kHz

    // Latched drawable size from main thread → consumed on render thread.
    // CGSize fits in two ints; reads/writes are word-sized so a lock is
    // overkill — use a small lock for clarity / future-proofing.
    private let drawableSizeLock = NSLock()
    private var pendingDrawableSize: CGSize = .zero
    private var hasPendingDrawableSize: Bool = false

    // Last applied internal size, recomputed when scale or drawable changes.
    private var appliedInternalSize: (Int, Int) = (0, 0)
    private var appliedDrawableSize: (Int, Int) = (0, 0)

    // Input handling (main thread)
    private let inputHandler = RemoteInputHandler()

    private var isSetUp = false
    private var isShuttingDown = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMetal()
        setupInput()

        // First preset load happens on render thread once the GL context is
        // current; queue it via the render loop.
        renderLoop.enqueue { [weak self] in self?.loadFirstPresetLocked() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("Metal is not available on this device")
            showFatalError("Metal not available")
            return
        }
        self.metalDevice = device

        guard let glMetalBridge = GLMetalBridge(device: device) else {
            logger.error("Failed to create GLMetalBridge")
            showFatalError("GL/Metal bridge failed")
            return
        }
        self.bridge = glMetalBridge

        guard let mtlRenderer = MetalRenderer(device: device,
                                              maxFramesInFlight: glMetalBridge.bufferCount) else {
            logger.error("Failed to create MetalRenderer")
            showFatalError("Metal renderer failed")
            return
        }
        self.metalRenderer = mtlRenderer

        // MTKView paused — we drive `draw()` from our own CADisplayLink.
        let metalView = MTKView(frame: view.bounds, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false   // permits MetalFX / shader-write paths
        metalView.depthStencilPixelFormat = .invalid
        metalView.preferredFramesPerSecond = 60
        metalView.autoResizeDrawable = true
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.delegate = nil            // we'll draw manually
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        view.addSubview(metalView)
        self.mtkView = metalView

        // Initial drawable size handshake — also re-latched in viewDidLayoutSubviews.
        let drawable = metalView.drawableSize
        latchDrawableSize(drawable)

        pcmDrainBuffer = .allocate(capacity: pcmDrainCapacityFrames * 2)

        // Render thread does the rest of init (binds GL context, builds
        // ProjectMRenderer, configures bridge to internal size).
        renderLoop.onFrame = { [weak self] in self?.drawFrame() }
        renderLoop.start()
        renderLoop.enqueue { [weak self] in self?.bootstrapOnRenderThread() }

        isSetUp = true
        renderLogger.info("Metal setup queued; render thread bootstrapping")
    }

    private func bootstrapOnRenderThread() {
        guard let bridge, let metalDevice else { return }
        EAGLContext.setCurrent(bridge.glContext)

        // Initial sizing.
        let (drawW, drawH) = currentLatchedDrawableSize()
        let scale = perfMonitor.currentScale
        let (intW, intH) = applyScale(width: drawW, height: drawH, scale: scale)

        bridge.resize(width: intW, height: intH)

        let pmRenderer = ProjectMRenderer(viewportSize: CGSize(width: drawW, height: drawH),
                                          scale: 1.0)
        if pmRenderer == nil {
            logger.error("Failed to create ProjectMRenderer on render thread")
            DispatchQueue.main.async { self.showFatalError("Rendering engine failed to start") }
            return
        }
        self.projectMRenderer = pmRenderer
        projectMRenderer?.setViewport(width: intW, height: intH)
        metalRenderer?.configure(internalWidth: intW, internalHeight: intH,
                                 drawableWidth: drawW, drawableHeight: drawH)
        appliedInternalSize = (intW, intH)
        appliedDrawableSize = (drawW, drawH)
        renderLogger.info("Render bootstrap complete: drawable=\(drawW)x\(drawH) internal=\(intW)x\(intH) scale=\(scale)")
        _ = metalDevice
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let metalView = mtkView {
            // Keep the view sized to its container (auto-resizing mask should
            // already do this; refresh drawable size latch).
            latchDrawableSize(metalView.drawableSize)
        }
    }

    // MARK: - Frame

    /// Render one frame. Called on the render thread by the display link.
    private func drawFrame() {
        guard isSetUp, !isShuttingDown,
              let bridge, let projectMRenderer, let metalRenderer, let view = mtkView else {
            return
        }

        // --- Pre-frame: process pending cross-thread tasks (preset loads etc) ---
        renderLoop.drainPendingTasks()

        // --- Adapt internal resolution if perf monitor recommends a change ---
        let scaleChanged = perfMonitor.tick()
        let (drawW, drawH) = currentLatchedDrawableSize()
        let drawableChanged = (drawW, drawH) != appliedDrawableSize
        if scaleChanged || drawableChanged {
            let (intW, intH) = applyScale(width: drawW, height: drawH,
                                          scale: perfMonitor.currentScale)
            if (intW, intH) != appliedInternalSize || drawableChanged {
                bridge.resize(width: intW, height: intH)
                projectMRenderer.setViewport(width: intW, height: intH)
                metalRenderer.configure(internalWidth: intW, internalHeight: intH,
                                        drawableWidth: drawW, drawableHeight: drawH)
                appliedInternalSize = (intW, intH)
                appliedDrawableSize = (drawW, drawH)
                renderLogger.info("Resolution adapted: internal=\(intW)x\(intH) (scale \(self.perfMonitor.currentScale)) drawable=\(drawW)x\(drawH)")
            }
        }

        // --- Frame-in-flight gate ---
        // Block until the GPU has finished a slot we can reuse. Combined with
        // the CVPixelBuffer round-robin, this guarantees we never overwrite a
        // slot Metal is still sampling.
        metalRenderer.semaphore.wait()

        // --- Drain audio ring buffer into projectM (variable, capped) ---
        if let ringBuffer = audioController?.ringBuffer,
           let drainBuf = pcmDrainBuffer {
            let framesRead = ringBuffer.read(into: drainBuf, maxFrames: pcmDrainCapacityFrames)
            if framesRead > 0 {
                projectMRenderer.addPCM(drainBuf,
                                        frameCount: UInt32(framesRead),
                                        channels: 2)
            }
        }

        // --- GL render projectM into the next CVPixelBuffer-backed FBO ---
        guard let (fbo, pixelBuffer) = bridge.nextFramebuffer() else {
            // Couldn't acquire a slot — release the semaphore we took above.
            metalRenderer.semaphore.signal()
            return
        }
        projectMRenderer.renderFrame(fbo: fbo)

        // Submit GL commands; IOSurface coherence + the Metal pass we
        // encode next provide the cross-API ordering Metal needs.
        bridge.flush()

        // --- Wrap output as Metal texture & encode upscale/blit + present ---
        // The CVMetalTexture lifetime handle is captured by the command
        // buffer's completion handler so the IOSurface stays valid until
        // the GPU is done sampling it.
        guard let (texture, lifetime) = bridge.metalTexture(from: pixelBuffer) else {
            metalRenderer.semaphore.signal()
            return
        }
        // MetalRenderer signals semaphore in its completion handler, even
        // on the no-drawable miss path.
        _ = metalRenderer.render(source: texture, in: view, lifetime: lifetime)
    }

    // MARK: - Scale helpers

    /// Compute internal size from drawable size and scale, snapping to even
    /// dimensions (some shaders/MetalFX prefer aligned widths).
    private func applyScale(width: Int, height: Int, scale: Float) -> (Int, Int) {
        let w = max(2, Int((Float(width)  * scale).rounded()) & ~1)
        let h = max(2, Int((Float(height) * scale).rounded()) & ~1)
        return (w, h)
    }

    private func latchDrawableSize(_ size: CGSize) {
        drawableSizeLock.lock()
        pendingDrawableSize = size
        hasPendingDrawableSize = true
        drawableSizeLock.unlock()
    }

    private func currentLatchedDrawableSize() -> (Int, Int) {
        drawableSizeLock.lock()
        let size = pendingDrawableSize
        drawableSizeLock.unlock()
        return (max(2, Int(size.width)), max(2, Int(size.height)))
    }

    // MARK: - Presets (called on render thread via renderLoop.enqueue)

    private func loadFirstPresetLocked() {
        guard let lib = presetLibrary, let url = lib.next() else { return }
        projectMRenderer?.loadPreset(at: url, smooth: false)
        DispatchQueue.main.async { [weak self] in
            self?.appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
        }
    }

    private func loadSpecificPreset(_ url: URL) {
        renderLoop.enqueue { [weak self] in
            guard let self else { return }
            self.presetLibrary?.jumpTo(url)
            self.projectMRenderer?.loadPreset(at: url, smooth: true)
            DispatchQueue.main.async {
                self.appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
                self.appState?.isPresetBrowserVisible = false
                self.inputHandler.setPresetBrowserVisible(false)
            }
        }
    }

    // MARK: - Input

    private func setupInput() {
        inputHandler.onCommand = { [weak self] command in self?.handleCommand(command) }
        appState?.onLoadPreset = { [weak self] url in self?.loadSpecificPreset(url) }
    }

    private func handleCommand(_ command: InputCommand) {
        appState?.recordInteraction()

        switch command {
        case .nextPreset:
            renderLoop.enqueue { [weak self] in
                guard let self, let url = self.presetLibrary?.next() else { return }
                self.projectMRenderer?.loadPreset(at: url, smooth: true)
                DispatchQueue.main.async {
                    self.appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
                }
            }
        case .previousPreset:
            renderLoop.enqueue { [weak self] in
                guard let self, let url = self.presetLibrary?.previous() else { return }
                self.projectMRenderer?.loadPreset(at: url, smooth: true)
                DispatchQueue.main.async {
                    self.appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
                }
            }
        case .toggleLock:
            if let state = appState {
                state.isLocked.toggle()
                let locked = state.isLocked
                renderLoop.enqueue { [weak self] in
                    self?.projectMRenderer?.setLocked(locked)
                }
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
            renderLoop.enqueue { [weak self] in
                guard let self else { return }
                self.presetLibrary?.shuffle()
                guard let url = self.presetLibrary?.next() else { return }
                self.projectMRenderer?.loadPreset(at: url, smooth: true)
                DispatchQueue.main.async {
                    self.appState?.currentPresetName = url.deletingPathExtension().lastPathComponent
                }
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

    // MARK: - Background / foreground

    @objc private func didEnterBackground() {
        // Pause new frames first.
        renderLoop.setPaused(true)
        // Run the suspend work synchronously on the render thread; this
        // wakes the (paused) run loop via perform(_:on:). Inside, we drain
        // any GPU work in flight, then flush GL + caches. We re-signal the
        // semaphore so subsequent draw frames after foreground can proceed.
        renderLoop.enqueueSync { [weak self] in
            guard let self else { return }
            if let renderer = self.metalRenderer {
                for _ in 0..<renderer.maxFramesInFlight { renderer.semaphore.wait() }
                for _ in 0..<renderer.maxFramesInFlight { renderer.semaphore.signal() }
            }
            if let ctx = self.bridge?.glContext, EAGLContext.current() === ctx {
                glFinish()
            }
            self.bridge?.flushCaches()
            self.perfMonitor.reset()
        }
    }

    @objc private func willEnterForeground() {
        renderLoop.setPaused(false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardown()
    }

    private func teardown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        // 1. Pause the display link so no new frames begin.
        renderLoop.setPaused(true)

        // 2. Synchronously, on the render thread, drain in-flight GPU work
        //    (so the completion handler closures release CVMetalTextures
        //    before we tear down the bridge), then release projectM and
        //    GL resources while the EAGL context is still current.
        renderLoop.enqueueSync { [weak self] in
            guard let self else { return }
            if let renderer = self.metalRenderer {
                for _ in 0..<renderer.maxFramesInFlight { renderer.semaphore.wait() }
                // Don't re-signal — we're shutting down.
            }
            self.projectMRenderer = nil   // releases projectM (deinit calls projectm_destroy)
            if let bridge = self.bridge {
                bridge.teardown()
            }
            self.bridge = nil
            EAGLContext.setCurrent(nil)
        }

        // 3. Stop the render thread (invalidates the display link on its
        //    own thread, then waits for thread exit).
        renderLoop.stop()

        mtkView?.delegate = nil
        pcmDrainBuffer?.deallocate()
        pcmDrainBuffer = nil
        isSetUp = false
    }

    deinit {
        teardown()
    }

    // MARK: - Fatal error display

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
