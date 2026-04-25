import Foundation
import Metal
#if !targetEnvironment(simulator)
import MetalFX
#endif

/// Wraps `MTLFXSpatialScaler` for cheap, high-quality upscaling from the
/// projectM render-resolution texture to the drawable.
///
/// **Simulator builds.** The MetalFX framework ships only with on-device
/// Apple TV SDKs, not the tvOS Simulator. On simulator, this type
/// instantiates fine but `isReady` is always false, and callers fall through
/// to the bilinear blit path in `MetalRenderer`.
///
/// **Device builds.** Falls back to bilinear blit when the GPU lacks the
/// Apple4 family required by MetalFX, or when input/output sizes match.
final class MetalFXUpscaler {
    private let device: MTLDevice
    private(set) var inputSize: (width: Int, height: Int) = (0, 0)
    private(set) var outputSize: (width: Int, height: Int) = (0, 0)
    private let colorTextureFormat: MTLPixelFormat
    private let outputTextureFormat: MTLPixelFormat

#if !targetEnvironment(simulator)
    private var scaler: MTLFXSpatialScaler?
#endif

    /// Returns nil only when the *device* doesn't support MetalFX. Simulator
    /// always returns a no-op instance whose `isReady` stays false.
    init?(device: MTLDevice,
          inputFormat: MTLPixelFormat = .bgra8Unorm,
          outputFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        self.colorTextureFormat = inputFormat
        self.outputTextureFormat = outputFormat

#if targetEnvironment(simulator)
        renderLogger.info("MetalFXUpscaler: simulator build — fallback blit will be used")
#else
        guard device.supportsFamily(.apple4) else {
            renderLogger.info("MetalFXUpscaler: device does not support Apple4 family; fallback path will be used")
            return nil
        }
#endif
    }

    /// (Re)build the scaler when sizes change. Cheap when sizes match.
    /// Returns true if a usable MetalFX scaler is configured.
    @discardableResult
    func configure(inputWidth: Int, inputHeight: Int,
                   outputWidth: Int, outputHeight: Int) -> Bool {
        guard inputWidth  > 0, inputHeight  > 0,
              outputWidth > 0, outputHeight > 0 else { return false }

#if targetEnvironment(simulator)
        // No MetalFX on simulator; just record sizes for the caller.
        inputSize  = (inputWidth,  inputHeight)
        outputSize = (outputWidth, outputHeight)
        return false
#else
        if scaler != nil,
           inputSize  == (inputWidth,  inputHeight),
           outputSize == (outputWidth, outputHeight) {
            return true
        }

        // No-op upscale: skip scaler entirely. Caller can use blit fallback.
        if inputWidth == outputWidth, inputHeight == outputHeight {
            scaler = nil
            inputSize  = (inputWidth, inputHeight)
            outputSize = (outputWidth, outputHeight)
            return false
        }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth   = inputWidth
        desc.inputHeight  = inputHeight
        desc.outputWidth  = outputWidth
        desc.outputHeight = outputHeight
        desc.colorTextureFormat  = colorTextureFormat
        desc.outputTextureFormat = outputTextureFormat
        desc.colorProcessingMode = .perceptual

        guard let s = desc.makeSpatialScaler(device: device) else {
            renderLogger.error("MetalFXUpscaler: failed to make spatial scaler for \(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)")
            scaler = nil
            return false
        }

        scaler = s
        inputSize  = (inputWidth,  inputHeight)
        outputSize = (outputWidth, outputHeight)
        renderLogger.info("MetalFXUpscaler: configured \(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)")
        return true
#endif
    }

    /// Encode a spatial-upscale pass on the given command buffer.
    /// Returns true if encoded; caller falls back to blit when false.
    func encode(input: MTLTexture, output: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
#if targetEnvironment(simulator)
        return false
#else
        guard let scaler else { return false }
        scaler.colorTexture  = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
        return true
#endif
    }

    var isReady: Bool {
#if targetEnvironment(simulator)
        return false
#else
        return scaler != nil
#endif
    }
}
