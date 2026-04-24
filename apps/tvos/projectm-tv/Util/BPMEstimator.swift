import Foundation

/// Fallback BPM estimation when MusicKit metadata lacks tempo info.
enum BPMEstimator {
    /// Default BPM for tracks without tempo metadata.
    static let defaultBPM: Double = 120.0

    /// Clamp BPM to reasonable range for visualization.
    static func clamp(_ bpm: Double) -> Double {
        return max(60, min(200, bpm))
    }
}
