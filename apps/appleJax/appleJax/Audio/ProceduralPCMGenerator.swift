import Foundation

/// Generates synthetic PCM that reacts to a beat grid, used when real audio tap is unavailable.
final class ProceduralPCMGenerator {
    private let ringBuffer: PCMRingBuffer
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "pm.procaudio", qos: .userInteractive)

    private var bpm: Double = 120.0
    private var isGenerating: Bool = false
    private var phase: Double = 0.0
    private var beatPhase: Double = 0.0
    private let sampleRate: Double = 48000.0
    private let chunkSize: Int = 1024

    // Pink noise state (Paul Kellet algorithm)
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    private var b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0

    // Pre-allocated buffer — avoids 8 KB heap allocation on every ~21 ms timer tick
    private let chunkBuffer: UnsafeMutablePointer<Float>

    init(ringBuffer: PCMRingBuffer) {
        self.ringBuffer = ringBuffer
        self.chunkBuffer = .allocate(capacity: chunkSize * 2)
    }

    deinit {
        stop()
        chunkBuffer.deallocate()
    }

    func setBPM(_ bpm: Double) {
        self.bpm = max(60, min(200, bpm))
    }

    func start() {
        guard !isGenerating else { return }
        isGenerating = true

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(chunkSize) / sampleRate
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.generateChunk()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        isGenerating = false
        timer?.cancel()
        timer = nil
    }

    private func generateChunk() {
        let buf = chunkBuffer

        let beatInterval = 60.0 / bpm
        let carrierAmp: Float = 0.0625  // -24 dBFS
        let burstAmp: Float = 0.5       // -6 dBFS
        let burstDuration: Double = 0.05 // 50ms
        let attackTime: Double = 0.005

        for i in 0..<chunkSize {
            // Pink noise carrier
            let white = Float.random(in: -1...1)
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
            b6 = white * 0.115926

            // Beat envelope
            let timeInBeat = beatPhase.truncatingRemainder(dividingBy: beatInterval)
            var envelope: Float = 0
            if timeInBeat < burstDuration {
                if timeInBeat < attackTime {
                    envelope = Float(timeInBeat / attackTime)
                } else {
                    let decay = (timeInBeat - attackTime) / (burstDuration - attackTime)
                    envelope = Float(exp(-3.0 * decay))
                }
            }

            // Bar modulation (every 4 beats)
            let barInterval = beatInterval * 4
            let barPhase = beatPhase.truncatingRemainder(dividingBy: barInterval)
            let barMod: Float = 1.0 + 0.3 * Float(sin(2.0 * .pi * barPhase / barInterval))

            let sample = pink * carrierAmp * barMod + envelope * burstAmp

            // Stereo with slight variation
            let whiteR = Float.random(in: -1...1)
            let pinkR = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + whiteR * 0.5362) * 0.11
            let sampleR = pinkR * carrierAmp * barMod + envelope * burstAmp * 0.95

            buf[i * 2] = sample
            buf[i * 2 + 1] = sampleR

            beatPhase += 1.0 / sampleRate
        }

        ringBuffer.write(buf, frameCount: chunkSize)
    }
}
