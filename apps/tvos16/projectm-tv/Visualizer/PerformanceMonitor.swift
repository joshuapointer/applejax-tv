import Foundation
import QuartzCore

/// Tracks rendering frame time and recommends an internal-resolution scale
/// factor to keep frames inside the target budget.
///
/// Scaling is discrete and hysteretic so the picture doesn't flicker: only
/// downscale when the moving average has been over budget for several frames,
/// only upscale when consistently under-budget with comfortable headroom.
final class PerformanceMonitor {
    /// Discrete scale steps. 1.0 = native; lower = render smaller, upscale.
    /// Tuned for tvOS 4K → render down to ~1280×720 if the GPU can't keep up.
    static let scaleSteps: [Float] = [1.0, 0.75, 0.5, 0.4, 0.33]

    /// Target frame budget. 16.6 ms = 60 fps.
    let targetFrameSeconds: Double

    /// EMA smoothing for instantaneous frame time.
    private let smoothing: Double = 0.1
    private var emaFrameSeconds: Double = 1.0 / 60.0

    /// Hysteresis counters — require N consecutive over/under budgets before
    /// changing scale, prevents flapping.
    private let downscaleConsecutiveThreshold = 12   // ~0.2 s @ 60 fps
    private let upscaleConsecutiveThreshold   = 180  // ~3 s of comfort
    private var overBudgetStreak  = 0
    private var underBudgetStreak = 0

    /// Comfort margin for upscaling. Only step up if EMA is well under budget.
    private let upscaleHeadroom: Double = 0.7  // need ≤70% of budget consistently

    private(set) var currentScaleIndex: Int = 0
    var currentScale: Float { Self.scaleSteps[currentScaleIndex] }

    private var lastTimestamp: CFTimeInterval = 0

    init(targetFps: Double = 60.0) {
        self.targetFrameSeconds = 1.0 / targetFps
    }

    /// Call once per frame, ideally just before drawing. Returns true if the
    /// recommended scale changed (caller should resize the bridge).
    @discardableResult
    func tick() -> Bool {
        let now = CACurrentMediaTime()
        defer { lastTimestamp = now }

        guard lastTimestamp > 0 else { return false }
        let dt = now - lastTimestamp
        // Reject obvious outliers (paused, app suspended).
        guard dt > 0, dt < 0.5 else {
            overBudgetStreak = 0
            underBudgetStreak = 0
            return false
        }

        emaFrameSeconds = (1.0 - smoothing) * emaFrameSeconds + smoothing * dt

        if emaFrameSeconds > targetFrameSeconds {
            overBudgetStreak += 1
            underBudgetStreak = 0
        } else if emaFrameSeconds < targetFrameSeconds * upscaleHeadroom {
            underBudgetStreak += 1
            overBudgetStreak = 0
        } else {
            // In the comfort band — neither.
            overBudgetStreak = 0
            underBudgetStreak = 0
        }

        if overBudgetStreak >= downscaleConsecutiveThreshold,
           currentScaleIndex < Self.scaleSteps.count - 1 {
            currentScaleIndex += 1
            overBudgetStreak = 0
            underBudgetStreak = 0
            return true
        }
        if underBudgetStreak >= upscaleConsecutiveThreshold,
           currentScaleIndex > 0 {
            currentScaleIndex -= 1
            overBudgetStreak = 0
            underBudgetStreak = 0
            return true
        }
        return false
    }

    /// Drop adaptive state — call after long pauses (background/foreground).
    func reset() {
        emaFrameSeconds = targetFrameSeconds
        overBudgetStreak = 0
        underBudgetStreak = 0
        lastTimestamp = 0
    }

    /// Snapshot for HUD/diagnostics.
    var smoothedFps: Double { emaFrameSeconds > 0 ? 1.0 / emaFrameSeconds : 0 }
}
