import Foundation
import Metal
import QuartzCore

/// Handles the Metal side of the rendering pipeline: blits a texture (from GL via GLMetalBridge)
/// to a CAMetalLayer drawable using a simple fullscreen triangle pass.
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    init?(device: MTLDevice) {
        self.device = device

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
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
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

        renderLogger.info("MetalRenderer: initialized successfully")
    }

    /// Blit the input texture (GL output) to a CAMetalLayer drawable.
    /// Safe to call from any thread — uses CAMetalLayer.nextDrawable() which is thread-safe.
    @discardableResult
    func render(texture: MTLTexture, drawable: any CAMetalDrawable) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return false
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }
}
