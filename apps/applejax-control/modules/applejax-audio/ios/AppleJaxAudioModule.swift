import AVFoundation
import ExpoModulesCore
import Foundation
import os.log

private let kSampleRate: Double = 22050
private let kChannels: AVAudioChannelCount = 1
private let kFramesPerChunk: AVAudioFrameCount = 1024
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
    // Serialises all engine/PCM state. Tap callbacks dispatch async onto this queue.
    // Never call sync from within an async block on this queue.
    private let engineQueue = DispatchQueue(label: "applejax.audio.engine", qos: .userInteractive)

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

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

    // MARK: - Session observers

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
        if let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
           reason == .oldDeviceUnavailable {
            engineQueue.async { [weak self] in
                guard let self, self.currentMode != "idle" else { return }
                self.tearDownEngineLocked()
                self.sendEvent("state", ["state": "idle", "error": "Audio device disconnected"])
            }
        }
    }

    // MARK: - Engine lifecycle (Locked = caller must hold engineQueue)

    private func tearDownEngineLocked() {
        removeSessionObservers()
        let was = currentMode
        currentMode = "idle"
        converter = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        if engine.attachedNodes.contains(playerNode) {
            engine.mainMixerNode.removeTap(onBus: 0)
            playerNode.stop()
            engine.detach(playerNode)
        }
        pendingFloats.removeAll(keepingCapacity: true)
        pendingHead = 0
        audioLog.info("Engine torn down (was: \(was))")
    }

    private func stopAll() {
        engineQueue.sync { tearDownEngineLocked() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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

        // Use nil format so AVAudioEngine delivers the hardware-native format — avoid
        // querying outputFormat(forBus:) before the engine starts, which can return
        // sampleRate=0 and produce a nil AVAudioConverter.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.engineQueue.async { self.handleIncomingLocked(buffer: buf) }
        }
        engine.prepare()
        let fmtAfterPrepare = engine.inputNode.outputFormat(forBus: 0)
        audioLog.info("Mic input format (post-prepare): sr=\(fmtAfterPrepare.sampleRate) ch=\(fmtAfterPrepare.channelCount)")
        try engine.start()
        audioLog.info("Engine started (mic)")
        currentMode = "mic"
    }

    // MARK: - File (Locked)

    private func beginFileLocked(uriString: String) throws {
        tearDownEngineLocked()
        let url: URL = uriString.contains("://")
            ? (URL(string: uriString) ?? URL(fileURLWithPath: uriString))
            : URL(fileURLWithPath: uriString)

        audioLog.info("Opening: \(url.lastPathComponent)")
        let file = try AVAudioFile(forReading: url)
        audioLog.info("File format: sr=\(file.processingFormat.sampleRate) ch=\(file.processingFormat.channelCount) frames=\(file.length)")

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.engineQueue.async { self.handleIncomingLocked(buffer: buf) }
        }

        engine.prepare()
        audioLog.info("Mixer output format (post-prepare): sr=\(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)")
        try engine.start()
        audioLog.info("Engine started (file)")

        playerNode.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            self.engineQueue.async {
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

        // Create converter lazily — buffer.format is always valid inside a tap callback,
        // unlike querying outputFormat(forBus:) before engine.start().
        if converter == nil {
            guard let outFmt = makeOutputFormat() else {
                audioLog.error("makeOutputFormat returned nil")
                return
            }
            if let conv = AVAudioConverter(from: buffer.format, to: outFmt) {
                audioLog.info("Converter ready: \(buffer.format.sampleRate)→\(outFmt.sampleRate) Hz, \(buffer.format.channelCount)ch→\(outFmt.channelCount)ch")
                converter = conv
            } else {
                audioLog.error("AVAudioConverter returned nil: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch → \(outFmt.sampleRate)Hz")
                tearDownEngineLocked()
                sendEvent("state", ["state": "idle",
                    "error": "Audio converter failed (\(Int(buffer.format.sampleRate))Hz \(buffer.format.channelCount)ch → \(Int(outFmt.sampleRate))Hz)"])
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
