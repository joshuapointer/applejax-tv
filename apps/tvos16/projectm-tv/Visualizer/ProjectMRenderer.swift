import Foundation
import OpenGLES

final class ProjectMRenderer {
    private var handle: OpaquePointer?

    /// Initialize projectM with the GL load_proc for tvOS.
    /// MUST be called while EAGLContext is current on the calling thread.
    init?(viewportSize: CGSize, scale: CGFloat) {
        handle = projectm_create_with_opengl_load_proc(projectm_tv_gl_load_proc, nil)
        guard handle != nil else {
            logger.error("projectm_create_with_opengl_load_proc returned NULL")
            return nil
        }
        renderLogger.info("projectM instance created successfully")

        let w = Int(viewportSize.width * scale)
        let h = Int(viewportSize.height * scale)
        projectm_set_window_size(handle, w, h)

        projectm_set_preset_duration(handle, 30.0)
        projectm_set_soft_cut_duration(handle, 3.0)

        renderLogger.info("Viewport set to \(w)x\(h)")
    }

    func setViewport(size: CGSize, scale: CGFloat) {
        guard let handle else { return }
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        projectm_set_window_size(handle, w, h)
    }

    /// Set viewport using pixel dimensions directly (from MTKView drawableSize).
    func setViewport(width: Int, height: Int) {
        guard let handle else { return }
        projectm_set_window_size(handle, width, height)
    }

    func loadPreset(at url: URL, smooth: Bool) {
        guard let handle else { return }
        url.path.withCString { path in
            projectm_load_preset_file(handle, path, smooth)
        }
        renderLogger.info("Loaded preset: \(url.lastPathComponent)")
    }

    func setLocked(_ locked: Bool) {
        guard let handle else { return }
        projectm_set_preset_locked(handle, locked)
    }

    func addPCM(_ samples: UnsafePointer<Float>, frameCount: UInt32, channels: UInt32) {
        guard let handle else { return }
        projectm_pcm_add_float(handle, samples, frameCount, PROJECTM_STEREO)
    }

    /// Render one frame into the specified off-screen FBO.
    /// The FBO is provided by GLMetalBridge (backed by a CVPixelBuffer).
    func renderFrame(fbo: GLuint) {
        guard let handle else { return }
        projectm_opengl_render_frame_fbo(handle, UInt32(fbo))
    }

    deinit {
        if let handle {
            projectm_destroy(handle)
            renderLogger.info("projectM instance destroyed")
        }
    }
}
