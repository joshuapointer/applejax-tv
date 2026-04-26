import AVFoundation

/// Audio source that plays local files via AVAudioEngine and taps PCM for the visualizer.
final class AudioEngineSource: AudioSource {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let ringBuffer: PCMRingBuffer
    private var audioFile: AVAudioFile?
    private(set) var nowPlaying: NowPlayingInfo?
    private(set) var isPlaying: Bool = false

    init(ringBuffer: PCMRingBuffer) {
        self.ringBuffer = ringBuffer
    }

    func loadFile(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        self.audioFile = file
        self.nowPlaying = NowPlayingInfo(
            title: url.deletingPathExtension().lastPathComponent,
            artist: "Local File",
            album: ""
        )
    }

    func start() throws {
        guard let audioFile else {
            throw NSError(domain: "AudioEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "No file loaded"])
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = audioFile.processingFormat
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Install tap on main mixer for PCM capture
        let ringBuf = self.ringBuffer
        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 2, interleaved: true)!

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            // For interleaved format, channel data is already interleaved
            ringBuf.write(channelData[0], frameCount: frameCount)
        }

        try engine.start()
        player.scheduleFile(audioFile, at: nil) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
            }
        }
        player.play()

        self.engine = engine
        self.playerNode = player
        self.isPlaying = true
    }

    func pause() {
        playerNode?.pause()
        isPlaying = false
    }

    func stop() {
        playerNode?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        playerNode = nil
        isPlaying = false
    }
}
