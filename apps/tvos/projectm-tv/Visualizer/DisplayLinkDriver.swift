import QuartzCore
import UIKit

final class DisplayLinkDriver {
    private var displayLink: CADisplayLink?
    private var tick: (() -> Void)?

    func start(_ tick: @escaping () -> Void) {
        self.tick = tick
        let link = CADisplayLink(target: self, selector: #selector(onTick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        displayLink?.isPaused = true
    }

    func resume() {
        displayLink?.isPaused = false
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        tick = nil
    }

    @objc private func onTick() {
        tick?()
    }

    deinit {
        stop()
    }
}
