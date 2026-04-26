import MusicKit
import Foundation

/// Audio source for Apple Music playback. Uses MusicKit's ApplicationMusicPlayer
/// and drives a procedural PCM generator since DRM prevents real audio tapping.
final class MusicKitSource: AudioSource {
    private let ringBuffer: PCMRingBuffer
    private let generator: ProceduralPCMGenerator
    private let player = ApplicationMusicPlayer.shared
    private(set) var nowPlaying: NowPlayingInfo?
    private(set) var isPlaying: Bool = false
    private var observationTask: Task<Void, Never>?

    init(ringBuffer: PCMRingBuffer) {
        self.ringBuffer = ringBuffer
        self.generator = ProceduralPCMGenerator(ringBuffer: ringBuffer)
    }

    /// Request MusicKit authorization. Returns true if authorized.
    static func requestAuthorization() async -> Bool {
        let status = await MusicAuthorization.request()
        return status == .authorized
    }

    func start() throws {
        generator.start()
        isPlaying = true
        startObservingPlayback()
    }

    func pause() {
        generator.stop()
        player.pause()
        isPlaying = false
    }

    func stop() {
        generator.stop()
        player.pause()
        observationTask?.cancel()
        observationTask = nil
        isPlaying = false
    }

    /// Play a specific song by its MusicKit ID.
    func play(song: Song) async throws {
        player.queue = [song]
        try await player.play()
        isPlaying = true
        generator.start()

        // MusicKit Song doesn't expose tempo on all SDK versions — default to 120 BPM
        generator.setBPM(BPMEstimator.defaultBPM)
        audioLogger.info("Using default BPM \(BPMEstimator.defaultBPM)")

        nowPlaying = NowPlayingInfo(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            bpm: BPMEstimator.defaultBPM
        )
    }

    private func startObservingPlayback() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in self.player.state.objectWillChange.values {
                _ = state // trigger observation
                let status = self.player.state.playbackStatus
                if status == .playing {
                    self.generator.start()
                    self.isPlaying = true
                } else {
                    self.generator.stop()
                    self.isPlaying = false
                }
            }
        }
    }

    /// Fetch recently played songs for the browse UI.
    static func fetchRecentlyPlayed() async throws -> [Song] {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = 25
        let response = try await request.response()
        return Array(response.items)
    }

    /// Fetch user's library songs.
    static func fetchLibrarySongs(limit: Int = 50) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        let response = try await request.response()
        return Array(response.items)
    }

    deinit {
        stop()
    }
}
