import Foundation

/// Lock-free single-producer single-consumer ring buffer for interleaved stereo float PCM.
/// Producer writes on the audio thread; consumer reads on the render/main thread.
final class PCMRingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacityFrames: Int
    private let capacitySamples: Int  // capacityFrames * 2 (stereo)

    // Atomic indices (in samples, not frames)
    private var writeIndex: UnsafeAtomic<Int>
    private var readIndex: UnsafeAtomic<Int>

    /// capacityFrames should be a power of 2 for efficient masking
    init(capacityFrames: Int = 8192) {
        self.capacityFrames = capacityFrames
        self.capacitySamples = capacityFrames * 2
        self.buffer = .allocate(capacity: capacitySamples)
        buffer.initialize(repeating: 0, count: capacitySamples)
        self.writeIndex = .create(0)
        self.readIndex = .create(0)
    }

    deinit {
        buffer.deallocate()
        writeIndex.destroy()
        readIndex.destroy()
    }

    /// Write interleaved stereo samples. Called from audio thread.
    /// Returns number of frames actually written.
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) -> Int {
        let sampleCount = frameCount * 2
        let currentWrite = writeIndex.load(ordering: .relaxed)
        let currentRead = readIndex.load(ordering: .acquiring)

        let available = capacitySamples - (currentWrite - currentRead)
        let toWrite = min(sampleCount, available)

        if toWrite <= 0 { return 0 }

        let writePos = currentWrite % capacitySamples
        let firstChunk = min(toWrite, capacitySamples - writePos)
        let secondChunk = toWrite - firstChunk

        buffer.advanced(by: writePos).update(from: samples, count: firstChunk)
        if secondChunk > 0 {
            buffer.update(from: samples.advanced(by: firstChunk), count: secondChunk)
        }

        writeIndex.store(currentWrite + toWrite, ordering: .releasing)
        return toWrite / 2
    }

    /// Read interleaved stereo samples into the provided buffer. Called from render thread.
    /// Returns number of frames actually read.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let maxSamples = maxFrames * 2
        let currentWrite = writeIndex.load(ordering: .acquiring)
        let currentRead = readIndex.load(ordering: .relaxed)

        let available = currentWrite - currentRead
        let toRead = min(maxSamples, available)

        if toRead <= 0 { return 0 }

        let readPos = currentRead % capacitySamples
        let firstChunk = min(toRead, capacitySamples - readPos)
        let secondChunk = toRead - firstChunk

        destination.update(from: buffer.advanced(by: readPos), count: firstChunk)
        if secondChunk > 0 {
            destination.advanced(by: firstChunk).update(from: buffer, count: secondChunk)
        }

        readIndex.store(currentRead + toRead, ordering: .releasing)
        return toRead / 2
    }

    var availableFrames: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return (w - r) / 2
    }
}

// MARK: - Minimal atomic wrapper (avoids swift-atomics dependency)

/// Minimal atomic integer using os_unfair_lock for correctness without external deps.
/// For a true lock-free path, replace with swift-atomics ManagedAtomic<Int>.
final class UnsafeAtomic<T: FixedWidthInteger> {
    private var value: T
    private var lock = os_unfair_lock()

    private init(_ value: T) {
        self.value = value
    }

    static func create(_ value: T) -> UnsafeAtomic<T> {
        return UnsafeAtomic(value)
    }

    func destroy() {
        // No-op for this implementation
    }

    enum Ordering {
        case relaxed, acquiring, releasing
    }

    func load(ordering: Ordering) -> T {
        os_unfair_lock_lock(&lock)
        let v = value
        os_unfair_lock_unlock(&lock)
        return v
    }

    func store(_ newValue: T, ordering: Ordering) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }
}
