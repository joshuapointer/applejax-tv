import Foundation
import Metal
import OpenGLES
import CoreVideo
import QuartzCore

/// Drives the full GL+Metal rendering pipeline on a dedicated background thread.
///
/// All projectM operations — including preset loading, which blocks on GL shader
/// compilation for 100–500 ms — happen on this thread. The main thread is never
/// stalled, so the UI stays responsive during every preset switch.
///
/// Inherits NSObject to use perform(_:on:with:waitUntilDone:) for cross-thread dispatch
/// to the render thread's RunLoop.
final class RenderEngine: NSObject {
    weak var audioController: AudioController?

    private let bridge: GLMetalBridge
    private let metalRenderer: MetalRenderer
    private let projectMRenderer: ProjectMRenderer
    private let metalLayer: CAMetalLayer
    private let pcmBuffer: UnsafeMutablePointer<Float>

    /// projectM renders to an offscreen FBO at this fraction of the layer's drawable size;
    /// the Metal blit pass bilinearly upscales the result. 0.5 ⇒ 1/4 the fragment work and
    /// 1/4 the shader-compile cost on preset transitions, which is the dominant stutter
    /// source on tvOS. Bilinear upscale of a Milkdrop-style frame is visually invisible
    /// at typical TV viewing distances.
    var renderScale: Double = 0.5

    private static let maxPCMFrames = 576

    // Audio diagnostic — accumulates between 1Hz log emissions.
    private var audioFramesPumped: Int = 0
    private var audioAmpAccum: Double = 0
    private var audioAmpSamples: Int = 0

    // Render thread state — accessed only on render thread
    private var renderThread: Thread?
    private var displayLink: CADisplayLink?

    // Signaled after displayLink is installed so start() callers see a consistent state.
    private let startupSemaphore = DispatchSemaphore(value: 0)

    // Signaled by doStopOnRenderThread so stop() can block until cleanup is complete.
    private let stopSemaphore = DispatchSemaphore(value: 0)

    // Pending preset request — written from main thread, consumed on render thread
    private let presetLock = NSLock()
    private var pendingPreset: (url: URL, smooth: Bool)?

    // Pending resize — consumed on render thread, which also updates metalLayer.drawableSize
    // to avoid the race between main-thread drawableSize mutation and nextDrawable() calls.
    private let resizeLock = NSLock()
    private var pendingResize: (width: Int, height: Int)?

    // Pending lock-state change
    private let lockStateLock = NSLock()
    private var pendingLockState: Bool?

    // FPS instrumentation — printed at 1 Hz from the render thread.
    private var frameTickCount: Int = 0
    private var fpsWindowStart: CFTimeInterval = 0

    // MARK: - Designated init (called only by the convenience init below)

    private init(bridge: GLMetalBridge,
                 metalRenderer: MetalRenderer,
                 projectMRenderer: ProjectMRenderer,
                 metalLayer: CAMetalLayer,
                 pcmBuffer: UnsafeMutablePointer<Float>) {
        self.bridge = bridge
        self.metalRenderer = metalRenderer
        self.projectMRenderer = projectMRenderer
        self.metalLayer = metalLayer
        self.pcmBuffer = pcmBuffer
        super.init()
    }

    // MARK: - Failable convenience init

    /// A convenience init? can return nil before calling self.init(), allowing us to
    /// run failable creation logic before any stored properties are set.
    convenience init?(device: MTLDevice, metalLayer: CAMetalLayer, pixelWidth: Int, pixelHeight: Int, renderScale: Double = 0.5) {
        guard let bridge = GLMetalBridge(device: device) else { return nil }
        guard let metalRenderer = MetalRenderer(device: device) else { return nil }

        let renderW = max(1, Int(Double(pixelWidth) * renderScale))
        let renderH = max(1, Int(Double(pixelHeight) * renderScale))

        EAGLContext.setCurrent(bridge.glContext)
        guard let pmRenderer = ProjectMRenderer(pixelWidth: renderW, pixelHeight: renderH) else {
            EAGLContext.setCurrent(nil)
            return nil
        }
        EAGLContext.setCurrent(nil)

        let pcmBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxPCMFrames * 2)

        self.init(bridge: bridge, metalRenderer: metalRenderer,
                  projectMRenderer: pmRenderer, metalLayer: metalLayer,
                  pcmBuffer: pcmBuffer)
        self.renderScale = renderScale

        // bridge.resize saves/restores the GL context internally.
        // GL FBO is at the reduced render size; Metal layer's drawable stays at full pixel size.
        bridge.resize(width: renderW, height: renderH)
        renderLogger.info("RenderEngine: GL render \(renderW)x\(renderH) → display \(pixelWidth)x\(pixelHeight) (scale \(renderScale))")
    }

    deinit {
        pcmBuffer.deallocate()
    }

    // MARK: - Control (called from main thread)

    /// Start the render thread. Blocks briefly (~1 ms) until the CADisplayLink is installed
    /// so that subsequent pause/resume/stop calls are guaranteed to work immediately.
    func start() {
        let t = Thread(target: self, selector: #selector(renderThreadMain), object: nil)
        t.name = "com.projectm.render"
        t.qualityOfService = .userInteractive
        t.start()
        renderThread = t
        startupSemaphore.wait()
    }

    /// Pause rendering synchronously. Blocks the calling thread until the render thread has
    /// finished its current frame and flushed all in-flight GL work. Required before tvOS
    /// suspends the process — late GL submissions cause the OS to terminate the app.
    func pauseRendering() {
        guard let thread = renderThread else { return }
        perform(#selector(doPauseOnRenderThread), on: thread, with: nil, waitUntilDone: true)
    }

    func resumeRendering() {
        guard let thread = renderThread else { return }
        perform(#selector(doResumeOnRenderThread), on: thread, with: nil, waitUntilDone: false)
    }

    /// Stop the render thread and block until it fully exits. Safe to call before VC dealloc —
    /// after this returns, pcmBuffer, the EAGLContext, and the projectM handle are all torn down.
    func stop() {
        guard let thread = renderThread else { return }
        renderThread = nil
        perform(#selector(doStopOnRenderThread), on: thread, with: nil, waitUntilDone: false)
        stopSemaphore.wait()
    }

    func requestPreset(_ url: URL, smooth: Bool) {
        presetLock.lock()
        pendingPreset = (url, smooth)
        presetLock.unlock()
    }

    func requestResize(pixelWidth: Int, pixelHeight: Int) {
        resizeLock.lock()
        pendingResize = (pixelWidth, pixelHeight)
        resizeLock.unlock()
    }

    func requestSetLocked(_ locked: Bool) {
        lockStateLock.lock()
        pendingLockState = locked
        lockStateLock.unlock()
    }

    // MARK: - Render thread

    @objc private func renderThreadMain() {
        EAGLContext.setCurrent(bridge.glContext)

        let link = CADisplayLink(target: self, selector: #selector(renderFrame))
        link.preferredFramesPerSecond = 60
        link.add(to: .current, forMode: .default)
        displayLink = link

        startupSemaphore.signal()   // unblock start()

        RunLoop.current.run()       // runs until doStopOnRenderThread calls CFRunLoopStop
    }

    @objc private func doPauseOnRenderThread() {
        displayLink?.isPaused = true
        glFinish()
    }

    @objc private func doResumeOnRenderThread() {
        displayLink?.isPaused = false
    }

    @objc private func doStopOnRenderThread() {
        displayLink?.invalidate()
        displayLink = nil
        glFinish()
        bridge.flushCaches()
        EAGLContext.setCurrent(nil)
        stopSemaphore.signal()
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    @objc private func renderFrame() {
        // Apply pending resize on the render thread so metalLayer.drawableSize is only
        // mutated here — never on the main thread while nextDrawable() is in flight.
        // GL/projectM render at renderScale of the layer's drawable size; Metal layer is full.
        resizeLock.lock()
        let resize = pendingResize
        pendingResize = nil
        resizeLock.unlock()
        if let (w, h) = resize {
            metalLayer.drawableSize = CGSize(width: w, height: h)
            let renderW = max(1, Int(Double(w) * renderScale))
            let renderH = max(1, Int(Double(h) * renderScale))
            bridge.resize(width: renderW, height: renderH)
            projectMRenderer.setViewport(width: renderW, height: renderH)
        }

        // Apply pending lock-state change
        lockStateLock.lock()
        let lockState = pendingLockState
        pendingLockState = nil
        lockStateLock.unlock()
        if let locked = lockState {
            projectMRenderer.setLocked(locked)
        }

        // Load pending preset — may block here on GL shader compilation.
        // This stalls the render thread only; the main thread stays responsive.
        presetLock.lock()
        let preset = pendingPreset
        pendingPreset = nil
        presetLock.unlock()
        if let (url, smooth) = preset {
            projectMRenderer.loadPreset(at: url, smooth: smooth)
        }

        guard let (fbo, mtlTexture) = bridge.nextFramebuffer() else { return }

        // Drain the ring buffer fully each frame, capped at 4096 frames so a single
        // render call can't get stuck pushing minutes of backlog. At 60 fps this is
        // exactly what 48 kHz audio produces; at the simulator's ~30 fps it lets us
        // catch up without leaving frames behind in the ring (which the receiver
        // would otherwise have to drop on overflow).
        if let rb = audioController?.ringBuffer {
            var totalDrained = 0
            while totalDrained < 4096 {
                let n = rb.read(into: pcmBuffer, maxFrames: Self.maxPCMFrames)
                if n == 0 { break }
                projectMRenderer.addPCM(pcmBuffer, frameCount: UInt32(n), channels: 2)
                audioFramesPumped += n
                let sampleStride = max(1, n / 16)
                var i = 0
                while i < n {
                    let l = pcmBuffer[i * 2]
                    let r = pcmBuffer[i * 2 + 1]
                    audioAmpAccum += Double(abs(l) + abs(r)) * 0.5
                    audioAmpSamples += 1
                    i += sampleStride
                }
                totalDrained += n
                if n < Self.maxPCMFrames { break }  // ring is empty
            }
        }

        projectMRenderer.renderFrame(fbo: fbo)

        // Hand off the IOSurface from GL to Metal: unbinds the FBO (forcing tile-resolve
        // on Apple's TBDR GPUs) and submits the GL command stream. The IOSurface tracker
        // serializes the subsequent Metal access — no glFinish CPU stall, full pipelining.
        bridge.finish()

        // CAMetalLayer.nextDrawable() is explicitly documented as safe from any thread.
        guard let drawable = metalLayer.nextDrawable() else { return }

        metalRenderer.render(texture: mtlTexture, drawable: drawable)

        frameTickCount += 1
        let now = CACurrentMediaTime()
        if fpsWindowStart == 0 {
            fpsWindowStart = now
        } else if now - fpsWindowStart >= 1.0 {
            let elapsed = now - fpsWindowStart
            let fps = Double(frameTickCount) / elapsed
            let avgAmp = audioAmpSamples > 0 ? audioAmpAccum / Double(audioAmpSamples) : 0
            let pumpRate = Double(audioFramesPumped) / elapsed
            // Use .notice so the line shows in Console.app live stream by default;
            // .info is memory-only on tvOS and silently dropped from streaming captures.
            // Mark values .public so Console.app's live stream renders them instead of
            // redacting to <private>. These are perf metrics, not user data — safe to expose.
            renderLogger.notice("RenderEngine fps=\(String(format: "%.1f", fps), privacy: .public) audio=\(String(format: "%.0f", pumpRate), privacy: .public)fr/s amp=\(String(format: "%.4f", avgAmp), privacy: .public)")
            frameTickCount = 0
            audioFramesPumped = 0
            audioAmpAccum = 0
            audioAmpSamples = 0
            fpsWindowStart = now
        }
    }
}
