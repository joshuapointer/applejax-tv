import UIKit
import GLKit
import OpenGLES

final class VisualizerViewController: UIViewController, GLKViewDelegate {
    private var glContext: EAGLContext?
    private var glkView: GLKView?
    private var displayLink: DisplayLinkDriver?
    private var renderer: ProjectMRenderer?
    private var isSetUp = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupGL()
    }

    private func setupGL() {
        guard let context = EAGLContextFactory.makeContext() else {
            logger.error("Cannot create EAGL context — fatal")
            showFatalError("OpenGL ES 3.0 not available")
            return
        }
        glContext = context
        EAGLContext.setCurrent(context)

        let glView = GLKView(frame: view.bounds, context: context)
        glView.delegate = self
        glView.drawableColorFormat = .RGBA8888
        glView.drawableDepthFormat = .format24
        glView.drawableStencilFormat = .format8
        glView.drawableMultisample = .multisampleNone
        glView.enableSetNeedsDisplay = true
        glView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glView.contentScaleFactor = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        view.addSubview(glView)
        self.glkView = glView

        // Create the projectM renderer
        let scale = glView.contentScaleFactor
        guard let pmRenderer = ProjectMRenderer(viewportSize: view.bounds.size, scale: scale) else {
            logger.error("Failed to create ProjectMRenderer")
            showFatalError("Rendering engine failed to start")
            return
        }
        self.renderer = pmRenderer
        isSetUp = true

        // Start the display link
        let driver = DisplayLinkDriver()
        driver.start { [weak self] in
            self?.glkView?.setNeedsDisplay()
        }
        self.displayLink = driver

        renderLogger.info("GL setup complete, display link started")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isSetUp else { return }
        let scale = glkView?.contentScaleFactor ?? 1.0
        renderer?.setViewport(size: view.bounds.size, scale: scale)
    }

    // MARK: - GLKViewDelegate

    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard isSetUp else { return }
        // Get the current FBO that GLKView has bound
        var currentFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &currentFBO)
        renderer?.renderFrame(intoFBO: currentFBO)
    }

    // MARK: - Lifecycle

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.stop()
    }

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
