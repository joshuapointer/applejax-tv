import Foundation
import Metal
import OpenGLES
import CoreVideo

/// Manages texture sharing between OpenGL ES and Metal.
///
/// **Device path (preferred)**: `CVPixelBufferPool` + `CVOpenGLESTextureCache` +
/// `CVMetalTextureCache` give us zero-copy GL→Metal interop on shared IOSurface storage.
/// `finish()` unbinds the FBO (forcing tile-resolve on Apple's TBDR GPUs) and `glFlush()`s;
/// IOSurface-level tracking handles cross-API serialization so the CPU never stalls.
///
/// **Simulator fallback**: The tvOS simulator's GL ES implementation does not support
/// IOSurface-backed textures (`CVOpenGLESTextureCacheCreateTextureFromImage` returns
/// `kCVReturnPixelBufferNotOpenGLCompatible` / -6683). When that happens, we drop into a
/// CPU-staged path: render to a plain GL texture, `glReadPixels` into a staging buffer, then
/// `MTLTexture.replace(region:)` into a `.shared`-storage Metal texture. Slow, but correct —
/// sufficient for testing app logic and audio reactivity in the sim.
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
    private var lastDrawnIndex = 0

    private(set) var width: Int = 0
    private(set) var height: Int = 0

    /// True when the IOSurface zero-copy path is unavailable (tvOS simulator). Selected
    /// at resize() time and used by `createFramebufferSlot` and `finish` to switch paths.
    private var useFallback: Bool = false
    private var fallbackStaging: UnsafeMutableRawPointer?

    private struct FramebufferSlot {
        var fbo: GLuint = 0
        var depthRenderbuffer: GLuint = 0
        // IOSurface-path fields
        var pixelBuffer: CVPixelBuffer?
        var glTexture: CVOpenGLESTexture?
        var cvMetalTexture: CVMetalTexture?
        // Fallback-path field (plain GL texture, not IOSurface-backed).
        var glTextureName: GLuint = 0
        // Either path produces an MTLTexture; both store it here.
        var mtlTexture: MTLTexture?
    }

    init?(device: MTLDevice) {
        self.device = device

        guard let context = EAGLContext(api: .openGLES3) else {
            renderLogger.error("GLMetalBridge: failed to create EAGLContext")
            return nil
        }
        self.glContext = context

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

    /// Resize the framebuffer pool. Idempotent on identical dimensions.
    /// Caller must have glContext current (or this method will set it).
    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != self.width || height != self.height else { return }

        let previousContext = EAGLContext.current()
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(previousContext) }

        destroyFramebuffers()

        self.width = width
        self.height = height

        // Try the IOSurface zero-copy path first by probing CVPixelBuffer creation.
        // If the simulator (or any other environment) can't honor GL-compat IOSurfaces,
        // we'll detect the failure during slot creation and switch modes.
        useFallback = false

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
        if poolStatus == kCVReturnSuccess, let pool {
            self.pixelBufferPool = pool
        } else {
            renderLogger.notice("GLMetalBridge: CVPixelBufferPoolCreate failed (\(poolStatus)) — falling back to CPU staging")
            self.useFallback = true
        }

        // Build the slots. If a slot fails on the IOSurface path, switch to fallback
        // and rebuild — the simulator hits this on the very first slot.
        for _ in 0..<bufferCount {
            if let slot = createFramebufferSlot() {
                framebuffers.append(slot)
            } else if !useFallback {
                renderLogger.notice("GLMetalBridge: IOSurface slot creation failed — switching to CPU fallback")
                useFallback = true
                // Tear down anything partial and rebuild all slots in fallback mode.
                tearDownPartialFramebuffers()
                pixelBufferPool = nil
                break
            }
        }

        if useFallback && framebuffers.isEmpty {
            for _ in 0..<bufferCount {
                if let slot = createFramebufferSlot() {
                    framebuffers.append(slot)
                }
            }
        }

        if useFallback {
            // Pre-allocate the row-pair staging buffer once.
            fallbackStaging?.deallocate()
            let bytes = width * height * 4
            fallbackStaging = .allocate(byteCount: bytes, alignment: 16)
        }

        if framebuffers.count != bufferCount {
            renderLogger.error("GLMetalBridge: only created \(self.framebuffers.count)/\(self.bufferCount) framebuffers (fallback=\(self.useFallback))")
        }

        currentIndex = 0
        lastDrawnIndex = 0
        renderLogger.notice("GLMetalBridge: resized to \(width)x\(height), \(self.framebuffers.count) buffers, fallback=\(self.useFallback)")
    }

    /// Get the next GL framebuffer for rendering and the matching pre-resolved MTLTexture.
    /// Rotates through the triple buffer. Caller must have glContext current.
    func nextFramebuffer() -> (fbo: GLuint, mtlTexture: MTLTexture)? {
        guard !framebuffers.isEmpty else { return nil }
        let slot = framebuffers[currentIndex]
        lastDrawnIndex = currentIndex
        currentIndex = (currentIndex + 1) % bufferCount
        guard let mtl = slot.mtlTexture else { return nil }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), slot.fbo)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        return (slot.fbo, mtl)
    }

    /// Hand off the just-rendered FBO to Metal.
    ///
    /// Device path: unbind the FBO (tile-resolve fires) and `glFlush()`. IOSurface tracking
    /// serializes the subsequent Metal sample.
    ///
    /// Fallback path: `glReadPixels` into our pre-allocated staging buffer (this implies a
    /// `glFinish`-equivalent sync inside the GL driver), then row-flip in place to convert
    /// GL's bottom-up convention to Metal's top-down convention, then upload to the slot's
    /// shared-storage MTLTexture via `replace(region:)`.
    func finish() {
        if useFallback {
            finishFallback()
            return
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glFlush()
    }

    private func finishFallback() {
        guard lastDrawnIndex < framebuffers.count else { return }
        let slot = framebuffers[lastDrawnIndex]
        guard let mtlTexture = slot.mtlTexture, let staging = fallbackStaging else {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            glFlush()
            return
        }
        // glReadPixels reads from the currently bound FBO. The slot we just drew to is still
        // bound here because the renderFrame loop hasn't unbound yet.
        glReadPixels(0, 0, GLsizei(width), GLsizei(height),
                     GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE),
                     staging)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)

        // Flip rows in place: row i ↔ row (height - 1 - i), for i in 0..<(height/2).
        let bpr = width * 4
        let bytes = staging.assumingMemoryBound(to: UInt8.self)
        var tmp = [UInt8](repeating: 0, count: bpr)
        tmp.withUnsafeMutableBufferPointer { tmpPtr in
            guard let tmpBase = tmpPtr.baseAddress else { return }
            for i in 0..<(height / 2) {
                let top = bytes.advanced(by: i * bpr)
                let bot = bytes.advanced(by: (height - 1 - i) * bpr)
                memcpy(tmpBase, top, bpr)
                memcpy(top, bot, bpr)
                memcpy(bot, tmpBase, bpr)
            }
        }

        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                size: MTLSize(width: width, height: height, depth: 1))
        mtlTexture.replace(region: region, mipmapLevel: 0,
                            withBytes: staging, bytesPerRow: bpr)
    }

    /// Flush texture caches. Call only on teardown / memory pressure — not per frame.
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
        if useFallback {
            return createFallbackSlot()
        }

        guard let pool = pixelBufferPool,
              let glTextureCache,
              let metalTextureCache else { return nil }

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

        var cvMtl: CVMetalTexture?
        let mtlStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            metalTextureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width, height,
            0,
            &cvMtl)
        guard mtlStatus == kCVReturnSuccess,
              let cvMtl,
              let mtlTexture = CVMetalTextureGetTexture(cvMtl) else {
            renderLogger.error("GLMetalBridge: CVMetalTextureCacheCreateTextureFromImage failed (\(mtlStatus))")
            glDeleteFramebuffers(1, &fbo)
            glDeleteRenderbuffers(1, &depthRB)
            return nil
        }

        return FramebufferSlot(
            fbo: fbo,
            depthRenderbuffer: depthRB,
            pixelBuffer: pixelBuffer,
            glTexture: cvGLTexture,
            cvMetalTexture: cvMtl,
            glTextureName: 0,
            mtlTexture: mtlTexture
        )
    }

    private func createFallbackSlot() -> FramebufferSlot? {
        // Plain GL texture (RGBA8) — no IOSurface, no texture cache.
        var glTex: GLuint = 0
        glGenTextures(1, &glTex)
        glBindTexture(GLenum(GL_TEXTURE_2D), glTex)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA,
                     GLsizei(width), GLsizei(height),
                     0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                               GLenum(GL_TEXTURE_2D), glTex, 0)

        var depthRB: GLuint = 0
        glGenRenderbuffers(1, &depthRB)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthRB)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH24_STENCIL8),
                              GLsizei(width), GLsizei(height))
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_STENCIL_ATTACHMENT),
                                  GLenum(GL_RENDERBUFFER), depthRB)

        let fbStatus = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if fbStatus != GLenum(GL_FRAMEBUFFER_COMPLETE) {
            renderLogger.error("GLMetalBridge[fallback]: framebuffer incomplete (status: \(fbStatus))")
            glDeleteTextures(1, &glTex)
            glDeleteFramebuffers(1, &fbo)
            glDeleteRenderbuffers(1, &depthRB)
            return nil
        }

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)

        // Metal target: shared-storage `.bgra8Unorm` so we can `replace(region:)` every frame
        // and the blit pass samples it directly. On Apple Silicon `.shared` is unified memory.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let mtlTexture = device.makeTexture(descriptor: desc) else {
            renderLogger.error("GLMetalBridge[fallback]: makeTexture failed")
            glDeleteTextures(1, &glTex)
            glDeleteFramebuffers(1, &fbo)
            glDeleteRenderbuffers(1, &depthRB)
            return nil
        }

        return FramebufferSlot(
            fbo: fbo,
            depthRenderbuffer: depthRB,
            pixelBuffer: nil,
            glTexture: nil,
            cvMetalTexture: nil,
            glTextureName: glTex,
            mtlTexture: mtlTexture
        )
    }

    private func tearDownPartialFramebuffers() {
        for var slot in framebuffers {
            if slot.fbo != 0 {
                glDeleteFramebuffers(1, &slot.fbo)
            }
            if slot.depthRenderbuffer != 0 {
                glDeleteRenderbuffers(1, &slot.depthRenderbuffer)
            }
            if slot.glTextureName != 0 {
                glDeleteTextures(1, &slot.glTextureName)
            }
        }
        framebuffers.removeAll()
    }

    private func destroyFramebuffers() {
        let previousContext = EAGLContext.current()
        if EAGLContext.current() !== glContext {
            EAGLContext.setCurrent(glContext)
        }

        tearDownPartialFramebuffers()

        if let glTextureCache {
            CVOpenGLESTextureCacheFlush(glTextureCache, 0)
        }
        if let metalTextureCache {
            CVMetalTextureCacheFlush(metalTextureCache, 0)
        }

        pixelBufferPool = nil

        fallbackStaging?.deallocate()
        fallbackStaging = nil

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
