import AVFoundation
import ExpoModulesCore
import Foundation

private let kSampleRate: Double = 22050
private let kChannels: AVAudioChannelCount = 1
private let kFramesPerChunk: AVAudioFrameCount = 1024

public class AppleJaxAudioModule: Module {
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private var converter: AVAudioConverter?
  private var pendingFloats: [Float] = []
  private var pendingHead: Int = 0
  private var currentMode: String = "idle"
  // Serializes ALL mutable engine/PCM state. Tap callbacks dispatch async,
  // begin/teardown dispatch sync. Never call sync while already on this queue.
  private let engineQueue = DispatchQueue(label: "applejax.audio.engine", qos: .userInteractive)

  public func definition() -> ModuleDefinition {
    Name("AppleJaxAudioModule")

    Constants([
      "sampleRate": kSampleRate,
      "channels": Int(kChannels),
      "framesPerChunk": Int(kFramesPerChunk)
    ])

    Events("pcm", "state")

    AsyncFunction("startMic") { (promise: Promise) in
      self.engineQueue.async {
        do {
          try self.activateSession(record: true)
          try self.beginMicLocked()
          self.sendEvent("state", ["state": "mic"])
          promise.resolve()
        } catch {
          self.tearDownEngineLocked()
          self.sendEvent("state", ["state": "idle", "error": error.localizedDescription])
          promise.reject("E_MIC", error.localizedDescription)
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
          self.sendEvent("state", ["state": "file"])
          promise.resolve()
        } catch {
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

  // MARK: - Session

  private func activateSession(record: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    if record {
      try session.setCategory(.playAndRecord, mode: .measurement,
                              options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
    } else {
      try session.setCategory(.playback, mode: .default,
                              options: [.mixWithOthers, .allowBluetoothA2DP])
    }
    try session.setActive(true, options: [])
  }

  // MARK: - Engine helpers (Locked = caller must hold engineQueue)

  private func tearDownEngineLocked() {
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    engine.mainMixerNode.removeTap(onBus: 0)
    if engine.attachedNodes.contains(playerNode) {
      playerNode.stop()
      engine.detach(playerNode)
    }
    pendingFloats.removeAll(keepingCapacity: true)
    pendingHead = 0
    converter = nil
    currentMode = "idle"
  }

  private func stopAll() {
    // removeTap inside the locked block prevents new tap callbacks; the
    // serial queue drains any in-flight handleIncoming before we mutate state.
    engineQueue.sync {
      tearDownEngineLocked()
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  private func makeOutputFormat() -> AVAudioFormat? {
    return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                         sampleRate: kSampleRate,
                         channels: kChannels,
                         interleaved: false)
  }

  // MARK: - Mic (Locked = caller must hold engineQueue)

  private func beginMicLocked() throws {
    tearDownEngineLocked()
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0 else {
      throw NSError(domain: "AppleJax", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Input has zero sample rate"])
    }
    guard let outFormat = makeOutputFormat() else {
      throw NSError(domain: "AppleJax", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to build output format"])
    }
    converter = AVAudioConverter(from: inFormat, to: outFormat)

    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
      guard let self else { return }
      // Copy buffer fields needed off the IO thread; AVAudioPCMBuffer is safe
      // to retain. Defer all state mutation to engineQueue.
      self.engineQueue.async {
        self.handleIncomingLocked(buffer: buffer, outFormat: outFormat)
      }
    }
    engine.prepare()
    try engine.start()
    currentMode = "mic"
  }

  // MARK: - File (Locked = caller must hold engineQueue)

  private func beginFileLocked(uriString: String) throws {
    tearDownEngineLocked()
    let url: URL
    if let parsed = URL(string: uriString), parsed.scheme != nil {
      url = parsed
    } else {
      url = URL(fileURLWithPath: uriString)
    }
    let file = try AVAudioFile(forReading: url)

    engine.attach(playerNode)
    let mixer = engine.mainMixerNode
    engine.connect(playerNode, to: mixer, format: file.processingFormat)

    let mixFormat = mixer.outputFormat(forBus: 0)
    guard let outFormat = makeOutputFormat() else {
      throw NSError(domain: "AppleJax", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to build output format"])
    }
    converter = AVAudioConverter(from: mixFormat, to: outFormat)

    mixer.installTap(onBus: 0, bufferSize: 2048, format: mixFormat) { [weak self] buffer, _ in
      guard let self else { return }
      self.engineQueue.async {
        self.handleIncomingLocked(buffer: buffer, outFormat: outFormat)
      }
    }

    engine.prepare()
    try engine.start()

    playerNode.scheduleFile(file, at: nil) { [weak self] in
      guard let self else { return }
      self.engineQueue.async {
        self.tearDownEngineLocked()
        self.sendEvent("state", ["state": "idle"])
      }
      try? AVAudioSession.sharedInstance().setActive(false,
                                                     options: [.notifyOthersOnDeactivation])
    }
    playerNode.play()
    currentMode = "file"
  }

  // MARK: - PCM pipeline (Locked = caller must hold engineQueue)

  private func handleIncomingLocked(buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
    guard let converter = self.converter else { return }
    let ratio = outFormat.sampleRate / buffer.format.sampleRate
    let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
      return
    }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
      if fed {
        inputStatus.pointee = .endOfStream
        return nil
      }
      fed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    if status == .error || outBuf.frameLength == 0 { return }

    guard let chData = outBuf.floatChannelData?[0] else { return }
    let count = Int(outBuf.frameLength)
    let appended = UnsafeBufferPointer(start: chData, count: count)
    pendingFloats.append(contentsOf: appended)

    let chunkSize = Int(kFramesPerChunk)
    while pendingFloats.count - pendingHead >= chunkSize {
      let start = pendingHead
      let end = start + chunkSize
      let slice = Array(pendingFloats[start..<end])
      pendingHead = end
      emitChunk(slice)
    }
    // Compact when wasted capacity grows large to bound memory.
    if pendingHead > 4096 {
      pendingFloats.removeFirst(pendingHead)
      pendingHead = 0
    }
  }

  private func emitChunk(_ samples: [Float]) {
    var sumSq: Double = 0
    for s in samples { sumSq += Double(s * s) }
    let rms = Float(sqrt(sumSq / Double(samples.count)))

    let data = samples.withUnsafeBufferPointer { ptr -> Data in
      Data(buffer: ptr)
    }
    let base64 = data.base64EncodedString()

    sendEvent("pcm", [
      "data": base64,
      "rms": rms,
      "frames": samples.count
    ])
  }
}
