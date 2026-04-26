import Foundation
import Combine

/// Protocol for audio sources that produce PCM for the visualizer.
protocol AudioSource: AnyObject {
    func start() throws
    func pause()
    func stop()
    var nowPlaying: NowPlayingInfo? { get }
    var isPlaying: Bool { get }
}

/// Routes audio from the active source into the shared PCM ring buffer.
final class AudioController: ObservableObject {
    let ringBuffer = PCMRingBuffer(capacityFrames: 8192)

    private(set) var activeSource: AudioSource?
    @Published var isPlaying: Bool = false

    func activate(_ source: AudioSource) {
        activeSource?.stop()
        activeSource = source
        do {
            try source.start()
            isPlaying = true
        } catch {
            audioLogger.error("Failed to start audio source: \(error.localizedDescription)")
            isPlaying = false
        }
    }

    func togglePlayPause() {
        guard let source = activeSource else { return }
        if isPlaying {
            source.pause()
            isPlaying = false
        } else {
            do {
                try source.start()
                isPlaying = true
            } catch {
                audioLogger.error("Failed to resume: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        activeSource?.stop()
        activeSource = nil
        isPlaying = false
    }
}
