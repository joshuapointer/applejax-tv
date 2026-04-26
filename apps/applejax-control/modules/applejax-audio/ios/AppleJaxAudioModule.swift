import AVFoundation
import ExpoModulesCore
import Foundation
import os.log

private let kSampleRate: Double = 22050
private let kChannels: AVAudioChannelCount = 1
private let kFramesPerChunk: AVAudioFrameCount = 1024
// 2-second back-pressure cap at the output sample rate
private let kMaxPendingFrames: Int = Int(kSampleRate) * 2
private let audioLog = os.Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.joshpointer.applejax.control",
    category: "AppleJaxAudio"
)

public class AppleJaxAudioModule: Module {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var pendingFloats: [Float] = []
    private var pendingHead: Int = 0
    private var currentMode: String = "idle"
    // Incremented by tearDownEngineLocked to invalidate queued tap callbacks from old sessions
    private var sessionGeneration: UInt64 = 0
    // Track which taps are installed so teardown is unconditional and correct
    private var inputTapInstalled = false
    private var mixerTapInstalled = false

    // Serialises all engine/PCM state. Tap callbacks dispatch async onto this queue.
    // Use stopAll() instead of engineQueue.sync to avoid deadlock from within the queue.
    private static let queueKey = DispatchSpecificKey<Void>()
    private lazy var engineQueue: DispatchQueue = {
        let q = DispatchQueue(label: "applejax.audio.engine", qos: .userInteractive)
        q.setSpecific(key: AppleJaxAudioModule.queueKey, value: ())
        return q
    }()

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    deinit {
        removeSessionObservers()
    }

    public func definition() -> ModuleDefinition {
        Name("AppleJaxAudioModule")

        Constants([
            "sampleRate": kSampleRate,
            "channels": Int(kChannels),
            "framesPerChunk": Int(kFramesPerChunk)
        ])

        Events("pcm", "state")

        AsyncFunction("startMic") { (promise: Promise) in
            self.requestMicPermission { granted in
                guard granted else {
                    audioLog.error("Microphone permission denied")
                    self.sendEvent("state", ["state": "idle", "error": "Microphone permission denied"])
                    promise.reject("E_PERMISSION", "Microphone permission denied")
                    return
                }
                self.engineQueue.async {
                    do {
                        try self.activateSession(record: true)
                        try self.beginMicLocked()
                        self.registerSessionObservers()
                        audioLog.info("startMic succeeded")
                        self.sendEvent("state", ["state": "mic"])
                        promise.resolve()
                    } catch {
                        audioLog.error("startMic failed: \(error.localizedDescription)")
                        self.tearDownEngineLocked()
                        self.sendEvent("state", ["state": "idle", "error": error.localizedDescription])
                        promise.reject("E_MIC", error.localizedDescription)
                    }
                }
            }
        }

        AsyncFunction("stopMic") { (promise: Promise) in
            self.stopAll()
            self.sendEvent("state", ["state": "idle"])
            promise.resolve()
        }

        AsyncFunction("playFile") { (uri: String, promise: Promise) in
            self.engineQueue.async {
                do {
                    try self.activateSession(record: false)
                    try self.beginFileLocked(uriString: uri)
                    self.registerSessionObservers()
                    audioLog.info("playFile succeeded")
                    self.sendEvent("state", ["state": "file"])
                    promise.resolve()
                } catch {
                    audioLog.error("playFile failed: \(error.localizedDescription)")
                    self.tearDownEngineLocked()
                    self.sendEvent("state", ["state": "idle", "error": error.localizedDescription])
                    promise.reject("E_FILE", error.localizedDescription)
                }
            }
        }

        AsyncFunction("stopFile") { (promise: Promise) in
            self.stopAll()
            self.sendEvent("state", ["state": "idle"])
            promise.resolve()
        }

        OnDestroy {
            self.stopAll()
        }
    }

    // MARK: - Permission

    private func requestMicPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                audioLog.info("Mic permission (iOS 17+): \(granted)")
                completion(granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                audioLog.info("Mic permission: \(granted)")
                completion(granted)
            }
        }
    }

    // MARK: - Session

    private func activateSession(record: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if record {
            // .allowBluetooth (HFP) is required for mic input over Bluetooth.
            // .allowBluetoothA2DP is output-only and does nothing for recording.
            try session.setCategory(
                .playAndRecord, mode: .measurement,
                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            )
        } else {
            try session.setCategory(
                .playback, mode: .default,
                options: [.mixWithOthers]
            )
        }
        try session.setActive(true, options: [])
        audioLog.info("Session active: sr=\(session.sampleRate) inCh=\(session.inputNumberOfChannels) outCh=\(session.outputNumberOfChannels)")
    }

    // MARK: - AVAudioSession notifications

    private func registerSessionObservers() {
        removeSessionObservers()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil
        ) { [weak self] note in self?.handleInterruption(note) }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil
        ) { [weak self] note in self?.handleRouteChange(note) }
    }

    private func removeSessionObservers() {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
        interruptionObserver = nil
        routeChangeObserver = nil
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeVal)
        else { return }
        if type == .began {
            audioLog.info("Session interrupted — tearing down")
            engineQueue.async { [weak self] in
                guard let self, self.currentMode != "idle" else { return }
                self.tearDownEngineLocked()
                self.sendEvent("state", ["state": "idle", "error": "Audio interrupted"])
            }
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt
        else { return }
        audioLog.info("Route changed: reason=\(reasonVal)")
        engineQueue.async { [weak self] in
            guard let self, self.currentMode != "idle" else { return }
            if let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
               reason == .oldDeviceUnavailable {
                self.tearDownEngineLocked()
                self.sendEvent("state", ["state": "idle", "error": "Audio device disconnected"])
            } else {
                // Non-fatal: invalidate the cached converter so the next tap callback
                // recreates it with the updated hardware format.
                self.converter = nil
                audioLog.info("Converter invalidated for route change \(reasonVal)")
            }
        }
    }

    // MARK: - Engine lifecycle (Locked = caller must hold engineQueue)

    private func tearDownEngineLocked() {
        removeSessionObservers()
        let was = currentMode
        currentMode = "idle"
        // Invalidate any in-flight tap callbacks from this session.
        sessionGeneration &+= 1
        converter = nil
        if engine.isRunning { engine.stop() }
        // Remove only the taps that were actually installed (avoids spurious log warnings).
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if mixerTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            mixerTapInstalled = false
        }
        if engine.attachedNodes.contains(playerNode) {
            playerNode.stop()
            engine.detach(playerNode)
        }
        pendingFloats.removeAll(keepingCapacity: true)
        pendingHead = 0
        audioLog.info("Engine torn down (was: \(was))")
    }

    /// Stops the engine and deactivates the AVAudioSession.
    /// Safe to call from any thread, including from within an engineQueue callback —
    /// re-entrance is detected via DispatchSpecificKey to avoid deadlock.
    private func stopAll() {
        let work: () -> Void = {
            self.tearDownEngineLocked()
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation]
            )
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work() // Already on engineQueue — call directly to avoid deadlock
        } else {
            engineQueue.sync(execute: work)
        }
    }

    private func makeOutputFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: kSampleRate,
            channels: kChannels,
            interleaved: false
        )
    }

    // MARK: - Mic (Locked)

    private func beginMicLocked() throws {
        tearDownEngineLocked()
        let generation = sessionGeneration

        // Install tap with nil format so AVAudioEngine delivers the hardware-native format.
        // Querying outputFormat(forBus:) before engine.start() can return sampleRate=0,
        // causing AVAudioConverter to return nil and silently drop all audio.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.engineQueue.async {
                guard self.sessionGeneration == generation else { return }
                self.handleIncomingLocked(buffer: buf)
            }
        }
        inputTapInstalled = true
        engine.prepare()
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        audioLog.info("Mic input format (post-prepare): sr=\(fmt.sampleRate) ch=\(fmt.channelCount)")
        try engine.start()
        audioLog.info("Engine started (mic)")
        currentMode = "mic"
    }

    // MARK: - File (Locked)

    private func beginFileLocked(uriString: String) throws {
        tearDownEngineLocked()
        let url: URL = {
            if let parsed = URL(string: uriString), parsed.scheme != nil { return parsed }
            return URL(fileURLWithPath: uriString)
        }()
        audioLog.info("Opening: \(url.lastPathComponent)")
        let file = try AVAudioFile(forReading: url)
        audioLog.info("File format: sr=\(file.processingFormat.sampleRate) ch=\(file.processingFormat.channelCount) frames=\(file.length)")

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

        let generation = sessionGeneration
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.engineQueue.async {
                guard self.sessionGeneration == generation else { return }
                self.handleIncomingLocked(buffer: buf)
            }
        }
        mixerTapInstalled = true

        engine.prepare()
        audioLog.info("Mixer output format (post-prepare): sr=\(self.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)")
        try engine.start()
        audioLog.info("Engine started (file)")

        playerNode.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            self.engineQueue.async {
                // Guard: user may have already called stopFile before natural playback end
                guard self.currentMode == "file" else { return }
                self.tearDownEngineLocked()
                self.sendEvent("state", ["state": "idle"])
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: [.notifyOthersOnDeactivation]
                )
            }
        }
        playerNode.play()
        currentMode = "file"
    }

    // MARK: - PCM pipeline (Locked)

    private func handleIncomingLocked(buffer: AVAudioPCMBuffer) {
        guard currentMode != "idle" else { return }

        // Rebuild converter if the input format changed (e.g. after a route change).
        if let existing = converter, existing.inputFormat != buffer.format {
            audioLog.info("Input format changed (\(buffer.format.sampleRate) Hz) — rebuilding converter")
            converter = nil
        }

        if converter == nil {
            guard let outFmt = makeOutputFormat() else {
                audioLog.error("makeOutputFormat returned nil")
                return
            }
            if let conv = AVAudioConverter(from: buffer.format, to: outFmt) {
                audioLog.info("Converter ready: \(buffer.format.sampleRate)→\(outFmt.sampleRate) Hz \(buffer.format.channelCount)→\(outFmt.channelCount)ch")
                converter = conv
            } else {
                audioLog.error("AVAudioConverter returned nil: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch → \(outFmt.sampleRate)Hz")
                tearDownEngineLocked()
                sendEvent("state", ["state": "idle",
                    "error": "Audio converter failed (\(Int(buffer.format.sampleRate))Hz → \(Int(outFmt.sampleRate))Hz)"])
                return
            }
        }

        guard let converter = self.converter else { return }
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: outCapacity) else { return }

        var fed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if let convErr {
            audioLog.error("Conversion error: \(convErr.localizedDescription)")
            return
        }
        if status == .error || outBuf.frameLength == 0 { return }

        guard let chData = outBuf.floatChannelData?[0] else { return }
        let count = Int(outBuf.frameLength)

        // Cap pending buffer to prevent unbounded growth when the TCP socket is slow.
        let pending = pendingFloats.count - pendingHead
        if pending + count > kMaxPendingFrames {
            let drop = (pending + count) - kMaxPendingFrames
            audioLog.warning("Pending overflow, dropping \(drop) samples")
            pendingHead = min(pendingHead + drop, pendingFloats.count)
        }

        pendingFloats.append(contentsOf: UnsafeBufferPointer(start: chData, count: count))

        let chunkSize = Int(kFramesPerChunk)
        while pendingFloats.count - pendingHead >= chunkSize {
            emitChunk(Array(pendingFloats[pendingHead..<(pendingHead + chunkSize)]))
            pendingHead += chunkSize
        }
        if pendingHead > 4096 {
            pendingFloats.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private func emitChunk(_ samples: [Float]) {
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s * s) }
        let rms = Float(sqrt(sumSq / Double(samples.count)))
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        sendEvent("pcm", [
            "data": data.base64EncodedString(),
            "rms": rms,
            "frames": samples.count
        ])
    }
}
