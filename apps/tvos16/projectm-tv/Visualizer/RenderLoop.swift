import Foundation
import QuartzCore

/// Dedicated render thread driven by a `CADisplayLink` running at the
/// display refresh rate.
///
/// All GL + Metal work happens here so SwiftUI / UIKit / AVFoundation work
/// no longer competes for the same 16.6 ms budget on the main thread.
///
/// **Cross-thread tasks.** Use `enqueue(_:)` for fire-and-forget work that
/// runs at the start of the next frame. Use `enqueueSync(_:)` for teardown
/// or background-suspension work that must run on the render thread *now*
/// — it wakes the run loop via `perform(_:on:)` so it works even when the
/// display link is paused.
///
/// **Lifecycle.** `start()` spawns the thread. `stop()` invalidates the
/// display link and cancels the thread *on the render thread itself*
/// (Apple requires `CADisplayLink.invalidate()` from its source thread).
/// Safe to call `stop()` from any thread; it returns once the render
/// thread has actually exited (or after a 1 s safety deadline).
final class RenderLoop {
    /// Fired on the render thread at display refresh rate.
    var onFrame: (() -> Void)?

    private var thread: Thread?
    private var displayLink: CADisplayLink?

    private let queueLock = NSLock()
    private var pendingTasks: [() -> Void] = []

    private let preferredFps: Int
    private(set) var isRunning: Bool = false

    init(preferredFps: Int = 60) {
        self.preferredFps = preferredFps
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let t = Thread(target: self, selector: #selector(threadMain), object: nil)
        t.name = "ProjectM.RenderThread"
        t.qualityOfService = .userInteractive
        t.start()
        self.thread = t
    }

    @objc private func threadMain() {
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFramesPerSecond = preferredFps
        link.add(to: .current, forMode: .common)
        self.displayLink = link

        // Park the run loop until cancelled. Wake periodically so isCancelled
        // and any cross-thread `perform(_:on:)` sources get serviced.
        while !Thread.current.isCancelled {
            RunLoop.current.run(mode: .default,
                                before: Date(timeIntervalSinceNow: 0.05))
        }

        // Tear down the display link on its own thread (required by Apple).
        link.invalidate()
        self.displayLink = nil
    }

    /// Stop the render thread cleanly. Returns once it has exited (or after
    /// a 1 s deadline). Safe from any thread.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        guard let t = thread, !t.isFinished else {
            thread = nil
            return
        }

        // Wake the parked run loop and ask the thread to cancel itself.
        t.cancel()
        let proxy = PerformProxy { /* no-op wake */ }
        proxy.perform(#selector(PerformProxy.run), on: t, with: nil,
                      waitUntilDone: false,
                      modes: [RunLoop.Mode.default.rawValue])

        // Bounded busy-wait for the thread to exit. We can't `join` a
        // Foundation Thread, so this is the canonical pattern.
        let deadline = Date(timeIntervalSinceNow: 1.0)
        while !t.isFinished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        thread = nil
    }

    func setPaused(_ paused: Bool) {
        // CADisplayLink.isPaused is documented thread-safe.
        displayLink?.isPaused = paused
    }

    /// Queue a closure to run on the render thread at the start of the next
    /// frame. Safe from any thread. Skipped silently if the display link
    /// is paused — use `enqueueSync` if you need work to drain regardless.
    func enqueue(_ block: @escaping () -> Void) {
        queueLock.lock()
        pendingTasks.append(block)
        queueLock.unlock()
    }

    /// Enqueue a closure and wait synchronously for it to complete on the
    /// render thread. Wakes the run loop via `perform(_:on:)`, so it works
    /// even when the display link is paused.
    ///
    /// Calls inline if invoked from the render thread itself or if the
    /// thread has already exited.
    func enqueueSync(_ block: @escaping () -> Void) {
        if let t = thread, Thread.current === t {
            block()
            return
        }
        guard let t = thread, !t.isFinished else {
            block()
            return
        }

        let done = DispatchSemaphore(value: 0)
        let proxy = PerformProxy {
            block()
            done.signal()
        }
        proxy.perform(#selector(PerformProxy.run), on: t, with: nil,
                      waitUntilDone: false,
                      modes: [RunLoop.Mode.default.rawValue])
        done.wait()
    }

    /// Drain pending cross-thread tasks. Called from the frame callback,
    /// after the GL context is current.
    func drainPendingTasks() {
        queueLock.lock()
        let tasks = pendingTasks
        pendingTasks.removeAll(keepingCapacity: true)
        queueLock.unlock()
        for task in tasks { task() }
    }

    @objc private func displayLinkFired() {
        onFrame?()
    }
}

/// NSObject shim used to route `perform(_:on:)` into a closure.
/// `Thread.perform` requires an `@objc` selector; this gives us one.
private final class PerformProxy: NSObject {
    let task: () -> Void
    init(_ task: @escaping () -> Void) {
        self.task = task
    }
    @objc func run() {
        task()
    }
}
