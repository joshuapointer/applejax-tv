import Foundation
import Metal
import OpenGLES
import CoreVideo

/// Manages zero-copy texture sharing between OpenGL ES and Metal via
/// `CVPixelBuffer` (IOSurface-backed on Apple Silicon).
///
/// Owns the off-screen `EAGLContext`, a `CVPixelBufferPool`,
/// `CVOpenGLESTextureCache`, and `CVMetalTextureCache`. GL renders into a
/// `CVPixelBuffer`-backed framebuffer; the same `CVPixelBuffer` is then
/// readable as an `MTLTexture` with no GPU copy.
///
/// **Threading.** This class is *not* thread-safe. The owning render thread
/// must keep `glContext` current, and all calls except `metalTexture(from:)`
/// must happen on that thread. `metalTexture(from:)` may be called from the
/// render thread immediately after `flush()` — `glFlush()` plus IOSurface
/// coherence guarantee Metal sees finished GL writes.
///
/// **Sizing.** The pool is sized to the projectM *internal* render
/// resolution, which may be smaller than the drawable resolution. The Metal
/// side is responsible for upscaling.
final class GLMetalBridge {
    let glContext: EAGLContext
    let device: MTLDevice

    private var glTextureCache: CVOpenGLESTextureCache?
    private var metalTextureCache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?

    /// Triple-buffered slots — one for GL writing, one for Metal reading,
    /// one in flight. The owning render thread also holds a frame-in-flight
    /// semaphore (count == `bufferCount`) to prevent overwriting a slot
    /// while Metal is still sampling it.
    let bufferCount = 3
    private var framebuffers: [FramebufferSlot] = []
    private var currentIndex = 0

    private(set) var width: Int = 0
    private(set) var height: Int = 0

    private struct FramebufferSlot {
        var fbo: GLuint = 0
        var depthRenderbuffer: GLuint = 0
        var pixelBuffer: CVPixelBuffer?
        var glTexture: CVOpenGLESTexture?
    }

    init?(device: MTLDevice) {
        self.device = device

        guard let context = EAGLContext(api: .openGLES3) else {
            renderLogger.error("GLMetalBridge: failed to create EAGLContext")
            return nil
        }
        self.glContext = context

        // Texture caches need the GL context current.
        let previousContext = EAGLContext.current()
        EAGLContext.setCurrent(context)
        defer { EAGLContext.setCurrent(previousContext) }

        var glCache: CVOpenGLESTextureCache?
        let glStatus = CVOpenGLESTextureCacheCreate(
            kCFAllocatorDefault, nil, context, nil, &glCache)
        guard glStatus == kCVReturnSuccess, let glCache else {
            renderLogger.error("GLMetalBridge: CVOpenGLESTextureCacheCreate failed (\(glStatus))")
            return nil
        }
        self.glTextureCache = glCache

        var mtlCache: CVMetalTextureCache?
        let mtlStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &mtlCache)
        guard mtlStatus == kCVReturnSuccess, let mtlCache else {
            renderLogger.error("GLMetalBridge: CVMetalTextureCacheCreate failed (\(mtlStatus))")
            return nil
        }
        self.metalTextureCache = mtlCache
    }

    /// Resize the framebuffer pool to the given internal-render resolution.
    /// Caller MUST have `glContext` current. No-op if size unchanged.
    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != self.width || height != self.height else { return }

        precondition(EAGLContext.current() === glContext,
                     "GLMetalBridge.resize must be called with glContext current")

        destroyFramebuffers()

        self.width = width
        self.height = height

        // Pool attributes — keep enough for double the slot count so resize
        // events don't immediately stall on pool exhaustion.
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: bufferCount
        ]
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferOpenGLESCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pixelBufferAttrs as CFDictionary,
            &pool)
        guard poolStatus == kCVReturnSuccess, let pool else {
            renderLogger.error("GLMetalBridge: CVPixelBufferPoolCreate failed (\(poolStatus))")
            return
        }
        self.pixelBufferPool = pool

        framebuffers = (0..<bufferCount).compactMap { _ in createFramebufferSlot() }
        if framebuffers.count != bufferCount {
            renderLogger.error("GLMetalBridge: only created \(self.framebuffers.count)/\(self.bufferCount) framebuffers")
        }

        currentIndex = 0
        renderLogger.info("GLMetalBridge: resized to \(width)x\(height), \(self.framebuffers.count) buffers")
    }

    /// Return the next GL FBO + backing CVPixelBuffer (round-robin). Caller
    /// MUST have `glContext` current and MUST have already waited on the
    /// frame-in-flight semaphore (count == `bufferCount`).
    func nextFramebuffer() -> (fbo: GLuint, pixelBuffer: CVPixelBuffer)? {
        guard !framebuffers.isEmpty else { return nil }
        let slot = framebuffers[currentIndex]
        currentIndex = (currentIndex + 1) % bufferCount
        guard let pb = slot.pixelBuffer else { return nil }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), slot.fbo)
        return (slot.fbo, pb)
    }

    /// Wrap a `CVPixelBuffer` as an `MTLTexture` (zero-copy). The vended
    /// texture is configured with `.shaderRead` usage so MetalFX or sampler
    /// passes can use it.
    ///
    /// Returns both the `MTLTexture` and its backing `CVMetalTexture`. The
    /// caller MUST keep the CVMetalTexture alive for the duration of any
    /// GPU work that samples the texture — typically by capturing it in the
    /// command buffer's `addCompletedHandler` closure. ARC then releases
    /// the IOSurface only after the GPU is done.
    func metalTexture(from pixelBuffer: CVPixelBuffer)
        -> (texture: MTLTexture, lifetime: CVMetalTexture)?
    {
        guard let metalTextureCache else { return nil }

        let attrs: [String: Any] = [
            kCVMetalTextureUsage as String: NSNumber(
                value: MTLTextureUsage([.shaderRead]).rawValue)
        ]

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            metalTextureCache,
            pixelBuffer,
            attrs as CFDictionary,
            .bgra8Unorm,
            width, height,
            0,
            &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else {
            renderLogger.error("GLMetalBridge: CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
            return nil
        }
        guard let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (mtlTexture, cvTexture)
    }

    /// Submit GL commands without waiting. Combined with the IOSurface
    /// coherence between GL and Metal queues, this is sufficient ordering
    /// before Metal samples the texture.
    func flush() {
        glFlush()
    }

    /// Flush the texture caches. Call on memory pressure or on background.
    /// Caller MUST have already drained any in-flight GPU work that may be
    /// sampling vended textures (e.g. by waiting on the renderer semaphore).
    func flushCaches() {
        if let glTextureCache {
            CVOpenGLESTextureCacheFlush(glTextureCache, 0)
        }
        if let metalTextureCache {
            CVMetalTextureCacheFlush(metalTextureCache, 0)
        }
    }

    /// Explicit teardown — must be called on the render thread (with
    /// `glContext` current) AFTER all in-flight GPU work has drained.
    /// GL resource deletion requires a current context.
    func teardown() {
        precondition(EAGLContext.current() === glContext,
                     "GLMetalBridge.teardown must be called with glContext current")
        destroyFramebuffers()
        if let glTextureCache {
            CVOpenGLESTextureCacheFlush(glTextureCache, 0)
        }
        if let metalTextureCache {
            CVMetalTextureCacheFlush(metalTextureCache, 0)
        }
        glTextureCache = nil
        metalTextureCache = nil
    }

    // MARK: - Private

    private func createFramebufferSlot() -> FramebufferSlot? {
        guard let pool = pixelBufferPool, let glTextureCache else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            renderLogger.error("GLMetalBridge: CVPixelBufferPoolCreatePixelBuffer failed (\(status))")
            return nil
        }

        var cvGLTexture: CVOpenGLESTexture?
        let texStatus = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            glTextureCache,
            pixelBuffer,
            nil,
            GLenum(GL_TEXTURE_2D),
            GL_RGBA,
            GLsizei(width), GLsizei(height),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_BYTE),
            0,
            &cvGLTexture)
        guard texStatus == kCVReturnSuccess, let cvGLTexture else {
            renderLogger.error("GLMetalBridge: CVOpenGLESTextureCacheCreateTextureFromImage failed (\(texStatus))")
            return nil
        }

        let textureName = CVOpenGLESTextureGetName(cvGLTexture)

        glBindTexture(GLenum(GL_TEXTURE_2D), textureName)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                               GLenum(GL_TEXTURE_2D), textureName, 0)

        // Depth+stencil sized to internal resolution → much smaller VRAM
        // footprint when scaling is active.
        var depthRB: GLuint = 0
        glGenRenderbuffers(1, &depthRB)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthRB)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH24_STENCIL8),
                              GLsizei(width), GLsizei(height))
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_STENCIL_ATTACHMENT),
                                  GLenum(GL_RENDERBUFFER), depthRB)

        let fbStatus = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if fbStatus != GLenum(GL_FRAMEBUFFER_COMPLETE) {
            renderLogger.error("GLMetalBridge: framebuffer incomplete (status: \(fbStatus))")
            glDeleteFramebuffers(1, &fbo)
            glDeleteRenderbuffers(1, &depthRB)
            return nil
        }

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)

        return FramebufferSlot(
            fbo: fbo,
            depthRenderbuffer: depthRB,
            pixelBuffer: pixelBuffer,
            glTexture: cvGLTexture
        )
    }

    private func destroyFramebuffers() {
        // Caller is responsible for ensuring glContext is current.
        for var slot in framebuffers {
            if slot.fbo != 0 {
                glDeleteFramebuffers(1, &slot.fbo)
            }
            if slot.depthRenderbuffer != 0 {
                glDeleteRenderbuffers(1, &slot.depthRenderbuffer)
            }
            // CVOpenGLESTexture and CVPixelBuffer released by ARC
        }
        framebuffers.removeAll()

        if let glTextureCache {
            CVOpenGLESTextureCacheFlush(glTextureCache, 0)
        }
        if let metalTextureCache {
            CVMetalTextureCacheFlush(metalTextureCache, 0)
        }

        pixelBufferPool = nil
        width = 0
        height = 0
    }

    deinit {
        // GL resources should already be torn down via teardown(); we can't
        // safely call GL deletion here because we're not guaranteed the
        // right thread/context.
    }
}
