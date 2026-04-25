import Foundation
import Metal
import MetalKit

/// Composites the projectM render-resolution texture onto the MTKView
/// drawable. Uses `MetalFXUpscaler` (spatial upscale) when input and output
/// sizes differ; falls back to a fullscreen-triangle blit shader otherwise.
///
/// Owns the in-flight semaphore so callers can wait at the start of each
/// frame; the completion handler signals it.
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blitPipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// Optional upscaler; nil means fallback blit only.
    private(set) var upscaler: MetalFXUpscaler?

    /// In-flight frame semaphore. Caller waits at the start of each frame;
    /// we signal in the command buffer's completion handler. Exposed so
    /// teardown / background-suspend logic can drain GPU work safely.
    let semaphore: DispatchSemaphore
    let maxFramesInFlight: Int

    /// Persistent, drawable-sized texture used as MetalFX output target.
    private var upscaleOutput: MTLTexture?
    private var upscaleOutputSize: (Int, Int) = (0, 0)

    init?(device: MTLDevice, maxFramesInFlight: Int) {
        self.device = device
        self.maxFramesInFlight = maxFramesInFlight
        self.semaphore = DispatchSemaphore(value: maxFramesInFlight)

        guard let queue = device.makeCommandQueue() else {
            renderLogger.error("MetalRenderer: failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            renderLogger.error("MetalRenderer: failed to load default Metal library")
            return nil
        }
        guard let vertexFunc = library.makeFunction(name: "blit_vertex") else {
            renderLogger.error("MetalRenderer: blit_vertex function not found")
            return nil
        }
        guard let fragmentFunc = library.makeFunction(name: "blit_fragment") else {
            renderLogger.error("MetalRenderer: blit_fragment function not found")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "ProjectM.BlitPipeline"
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            blitPipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            renderLogger.error("MetalRenderer: pipeline state creation failed: \(error.localizedDescription)")
            return nil
        }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDesc) else {
            renderLogger.error("MetalRenderer: failed to create sampler state")
            return nil
        }
        self.sampler = samplerState

        self.upscaler = MetalFXUpscaler(device: device)
        renderLogger.info("MetalRenderer: initialized (MetalFX: \(self.upscaler?.isReady == true ? "available" : "fallback only"))")
    }

    /// Reconfigure for new internal/drawable sizes.
    func configure(internalWidth: Int, internalHeight: Int,
                   drawableWidth: Int, drawableHeight: Int) {
        let needsUpscale = (internalWidth != drawableWidth) || (internalHeight != drawableHeight)
        if needsUpscale, let upscaler {
            _ = upscaler.configure(
                inputWidth: internalWidth, inputHeight: internalHeight,
                outputWidth: drawableWidth, outputHeight: drawableHeight)
        }
        ensureUpscaleOutput(width: drawableWidth, height: drawableHeight)
    }

    private func ensureUpscaleOutput(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if upscaleOutput != nil, upscaleOutputSize == (width, height) { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        upscaleOutput = device.makeTexture(descriptor: desc)
        upscaleOutput?.label = "ProjectM.UpscaleOutput"
        upscaleOutputSize = (width, height)
    }

    /// Encode + commit a render to the MTKView drawable.
    ///
    /// The optional `lifetime` is captured by the command buffer's completion
    /// handler — pass the source texture's `CVMetalTexture` (the CV-side
    /// retain handle) so the underlying IOSurface stays valid until the GPU
    /// is done sampling it.
    ///
    /// Signals the in-flight semaphore on every exit path: completion
    /// handler on success, immediately on early-return / encode-failure.
    /// Returns false on a missed frame.
    @discardableResult
    func render(source: MTLTexture, in view: MTKView, lifetime: AnyObject? = nil) -> Bool {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else {
            semaphore.signal()
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            semaphore.signal()
            return false
        }
        commandBuffer.label = "ProjectM.Frame"

        let drawableW = drawable.texture.width
        let drawableH = drawable.texture.height
        let needsUpscale = (source.width != drawableW) || (source.height != drawableH)

        var encoded = false
        if needsUpscale, let upscaler, upscaler.isReady,
           let upscaled = upscaleOutput,
           upscaled.width == drawableW, upscaled.height == drawableH {
            // Path A: MetalFX spatial upscale → intermediate → blit to drawable.
            if upscaler.encode(input: source, output: upscaled, commandBuffer: commandBuffer) {
                encoded = encodeBlit(source: upscaled, passDescriptor: passDescriptor, in: commandBuffer)
            }
        } else {
            // Path B: direct fragment-shader blit (handles bilinear upscale
            // and 1:1 pass-through).
            encoded = encodeBlit(source: source, passDescriptor: passDescriptor, in: commandBuffer)
        }

        if !encoded {
            // Don't commit an empty buffer (would present a black drawable).
            semaphore.signal()
            return false
        }

        let sema = semaphore
        let life = lifetime  // captured so ARC keeps it until GPU completes.
        commandBuffer.addCompletedHandler { _ in
            sema.signal()
            _ = life
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func encodeBlit(source: MTLTexture,
                            passDescriptor: MTLRenderPassDescriptor,
                            in commandBuffer: MTLCommandBuffer) -> Bool {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return false
        }
        encoder.label = "ProjectM.BlitToDrawable"
        encoder.setRenderPipelineState(blitPipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
