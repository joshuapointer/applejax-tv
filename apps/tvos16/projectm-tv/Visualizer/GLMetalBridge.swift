import Foundation
import Metal
import OpenGLES
import CoreVideo

/// Manages zero-copy texture sharing between OpenGL ES and Metal via CVPixelBuffer.
///
/// Owns the EAGLContext (off-screen GL), CVPixelBufferPool (triple-buffered),
/// CVOpenGLESTextureCache, and CVMetalTextureCache. GL renders into a CVPixelBuffer-backed
/// framebuffer; the same CVPixelBuffer is then readable as an MTLTexture with no GPU copy
/// on Apple Silicon's unified memory.
final class GLMetalBridge {
    let glContext: EAGLContext
    let device: MTLDevice

    private var glTextureCache: CVOpenGLESTextureCache?
    private var metalTextureCache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?

    // Triple-buffered: GL writes to one, Metal reads another, third in flight.
    private let bufferCount = 3
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

        // Create texture caches
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

    /// Resize the framebuffer pool. Call when MTKView drawable size changes.
    /// Must be called at least once before rendering.
    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != self.width || height != self.height else { return }

        let previousContext = EAGLContext.current()
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(previousContext) }

        // Tear down existing
        destroyFramebuffers()

        self.width = width
        self.height = height

        // Create CVPixelBufferPool
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

        // Pre-allocate framebuffer slots
        framebuffers = (0..<bufferCount).compactMap { _ in
            createFramebufferSlot()
        }

        if framebuffers.count != bufferCount {
            renderLogger.error("GLMetalBridge: only created \(framebuffers.count)/\(bufferCount) framebuffers")
        }

        currentIndex = 0
        renderLogger.info("GLMetalBridge: resized to \(width)x\(height), \(framebuffers.count) buffers")
    }

    /// Get the next GL framebuffer for rendering. Rotates through the triple buffer.
    /// Caller must have glContext current.
    func nextFramebuffer() -> (fbo: GLuint, pixelBuffer: CVPixelBuffer)? {
        guard !framebuffers.isEmpty else { return nil }
        let slot = framebuffers[currentIndex]
        currentIndex = (currentIndex + 1) % bufferCount
        guard let pb = slot.pixelBuffer else { return nil }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), slot.fbo)
        return (slot.fbo, pb)
    }

    // Retained to keep the MTLTexture valid through the Metal render pass.
    // CVMetalTexture must outlive the MTLTexture it vends.
    private var currentCVMetalTexture: CVMetalTexture?

    /// Wrap a CVPixelBuffer as an MTLTexture (zero-copy on unified memory).
    /// The returned MTLTexture is valid until the next call to this method.
    func metalTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let metalTextureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            metalTextureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width, height,
            0,
            &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else {
            renderLogger.error("GLMetalBridge: CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
            return nil
        }
        currentCVMetalTexture = cvTexture
        return CVMetalTextureGetTexture(cvTexture)
    }

    /// Flush GL commands. Call after projectM rendering, before Metal reads the texture.
    func flush() {
        glFlush()
    }

    /// Flush texture caches. Call periodically or on memory pressure.
    func flushCaches() {
        if let glTextureCache {
            CVOpenGLESTextureCacheFlush(glTextureCache, 0)
        }
        if let metalTextureCache {
            CVMetalTextureCacheFlush(metalTextureCache, 0)
        }
    }

    // MARK: - Private

    private func createFramebufferSlot() -> FramebufferSlot? {
        guard let pool = pixelBufferPool, let glTextureCache else { return nil }

        // Allocate CVPixelBuffer from pool
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            renderLogger.error("GLMetalBridge: CVPixelBufferPoolCreatePixelBuffer failed (\(status))")
            return nil
        }

        // Create GL texture from CVPixelBuffer
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

        // Configure texture
        glBindTexture(GLenum(GL_TEXTURE_2D), textureName)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // Create FBO
        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                               GLenum(GL_TEXTURE_2D), textureName, 0)

        // Create depth+stencil renderbuffer
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
        let previousContext = EAGLContext.current()
        if EAGLContext.current() !== glContext {
            EAGLContext.setCurrent(glContext)
        }

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

        if EAGLContext.current() !== previousContext {
            EAGLContext.setCurrent(previousContext)
        }
    }

    deinit {
        destroyFramebuffers()
        glTextureCache = nil
        metalTextureCache = nil
    }
}
