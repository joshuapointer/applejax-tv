import GLKit
import OpenGLES

enum EAGLContextFactory {
    /// Create an OpenGL ES 3.0 context for tvOS.
    static func makeContext() -> EAGLContext? {
        guard let context = EAGLContext(api: .openGLES3) else {
            logger.error("Failed to create EAGL context with OpenGL ES 3.0")
            return nil
        }
        return context
    }
}
