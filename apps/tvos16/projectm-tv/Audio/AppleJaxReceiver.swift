import Foundation
import Network

/// TCP receiver for the appleJax Control companion iPhone app.
///
/// Wire protocol (per-frame):
///   4 bytes  ASCII magic "APJX"
///   4 bytes  uint32 LE  payload byte length (= sampleCount * 4)
///   N bytes  Float32 LE PCM, mono, 22050 Hz
///
/// Resamples to the visualizer's expected 48000 Hz stereo (linear, mono→duplicated)
/// and writes into the shared PCMRingBuffer.
final class AppleJaxReceiver: AudioSource {
    static let defaultPort: UInt16 = 9999
    private static let inSampleRate: Double = 22050
    private static let outSampleRate: Double = 48000
    private static let resampleRatio: Double = inSampleRate / outSampleRate
    private static let magic: [UInt8] = [0x41, 0x50, 0x4A, 0x58] // "APJX"
    private static let headerSize: Int = 8

    private let ringBuffer: PCMRingBuffer
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "applejax.receiver", qos: .userInteractive)

    private var listener: NWListener?
    private var connection: NWConnection?
    private var inbox = Data()  // accumulated unparsed bytes

    // Cross-thread state (UI may read while `queue` writes). Protected by lock.
    private var stateLock = os_unfair_lock()
    private var _listenPort: UInt16 = 0
    private var _clientDescription: String = "(no client)"
    private var _isPlaying: Bool = false

    var listenPort: UInt16 {
        os_unfair_lock_lock(&stateLock); defer { os_unfair_lock_unlock(&stateLock) }
        return _listenPort
    }
    var clientDescription: String {
        os_unfair_lock_lock(&stateLock); defer { os_unfair_lock_unlock(&stateLock) }
        return _clientDescription
    }
    var isPlaying: Bool {
        os_unfair_lock_lock(&stateLock); defer { os_unfair_lock_unlock(&stateLock) }
        return _isPlaying
    }
    private func setIsPlaying(_ value: Bool) {
        os_unfair_lock_lock(&stateLock); _isPlaying = value; os_unfair_lock_unlock(&stateLock)
    }
    private func setListenPort(_ value: UInt16) {
        os_unfair_lock_lock(&stateLock); _listenPort = value; os_unfair_lock_unlock(&stateLock)
    }
    private func setClientDescription(_ value: String) {
        os_unfair_lock_lock(&stateLock); _clientDescription = value; os_unfair_lock_unlock(&stateLock)
    }
    var nowPlaying: NowPlayingInfo? {
        return NowPlayingInfo(title: "appleJax Control",
                              artist: clientDescription,
                              album: "Live PCM",
                              bpm: nil)
    }

    init(ringBuffer: PCMRingBuffer, port: UInt16 = AppleJaxReceiver.defaultPort) {
        self.ringBuffer = ringBuffer
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: AppleJaxReceiver.defaultPort)!
    }

    // MARK: - AudioSource

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }
        let listener = try NWListener(using: params, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let p = listener.port?.rawValue ?? 0
                self.setListenPort(p)
                audioLogger.info("AppleJaxReceiver listening on TCP \(p)")
            case .failed(let err):
                audioLogger.error("AppleJaxReceiver listener failed: \(err.localizedDescription)")
            case .cancelled:
                audioLogger.info("AppleJaxReceiver listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.adopt(connection: conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        setIsPlaying(true)
    }

    func pause() {
        // No backpressure to companion. Treat as stop.
        stop()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.inbox.removeAll(keepingCapacity: false)
            self.setListenPort(0)
            self.setClientDescription("(no client)")
        }
        setIsPlaying(false)
    }

    // MARK: - Connection lifecycle

    private func adopt(connection conn: NWConnection) {
        // Single-client model: drop any existing connection.
        if let old = self.connection {
            old.cancel()
        }
        self.connection = conn
        self.inbox.removeAll(keepingCapacity: true)
        let desc = describe(endpoint: conn.endpoint)
        setClientDescription(desc)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                audioLogger.info("AppleJaxReceiver client connected: \(desc)")
                self.scheduleReceive(on: conn)
            case .failed(let err):
                audioLogger.error("AppleJaxReceiver client failed: \(err.localizedDescription)")
                self.dropConnection(conn)
            case .cancelled:
                audioLogger.info("AppleJaxReceiver client cancelled")
                self.dropConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func dropConnection(_ conn: NWConnection) {
        if conn === self.connection {
            self.connection = nil
            self.inbox.removeAll(keepingCapacity: false)
            setClientDescription("(no client)")
        }
    }

    private func describe(endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let p):
            return "\(host):\(p)"
        case .service(let name, _, _, _):
            return name
        case .url(let url):
            return url.absoluteString
        case .unix(let path):
            return path
        case .opaque:
            return "(opaque)"
        @unknown default:
            return "(unknown)"
        }
    }

    // MARK: - Receive loop

    private func scheduleReceive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbox.append(data)
                self.parse()
            }
            if let error {
                audioLogger.error("AppleJaxReceiver receive error: \(error.localizedDescription)")
                self.dropConnection(conn)
                return
            }
            if isComplete {
                self.dropConnection(conn)
                return
            }
            self.scheduleReceive(on: conn)
        }
    }

    private func parse() {
        let headerSize = AppleJaxReceiver.headerSize
        while inbox.count >= headerSize {
            // Validate magic.
            let m0 = inbox[inbox.startIndex]
            let m1 = inbox[inbox.startIndex + 1]
            let m2 = inbox[inbox.startIndex + 2]
            let m3 = inbox[inbox.startIndex + 3]
            let magic = AppleJaxReceiver.magic
            if m0 != magic[0] || m1 != magic[1] || m2 != magic[2] || m3 != magic[3] {
                // Resync: scan forward to next 'A'.
                if let next = inbox.firstIndex(where: { $0 == magic[0] }), next > inbox.startIndex {
                    inbox.removeSubrange(inbox.startIndex..<next)
                    continue
                } else {
                    inbox.removeAll(keepingCapacity: true)
                    return
                }
            }
            // Parse little-endian payload length.
            let lenBase = inbox.startIndex + 4
            let payloadLen: UInt32 = (UInt32(inbox[lenBase])
                | (UInt32(inbox[lenBase + 1]) << 8)
                | (UInt32(inbox[lenBase + 2]) << 16)
                | (UInt32(inbox[lenBase + 3]) << 24))
            let payloadCount = Int(payloadLen)

            // Sanity bound (~64 KiB / chunk max).
            if payloadCount > 256 * 1024 {
                audioLogger.error("AppleJaxReceiver oversized frame (\(payloadCount)B), resyncing")
                inbox.removeFirst(1)
                continue
            }

            let frameTotal = headerSize + payloadCount
            if inbox.count < frameTotal { break } // wait for more bytes

            // Extract payload and consume.
            let payload = inbox.subdata(in: (inbox.startIndex + headerSize)..<(inbox.startIndex + frameTotal))
            inbox.removeFirst(frameTotal)

            ingest(monoFloat32LE: payload)
        }
    }

    // MARK: - PCM ingest

    private func ingest(monoFloat32LE data: Data) {
        let monoCount = data.count / 4
        if monoCount == 0 { return }

        // Decode mono Float32 LE into a typed array.
        var mono = [Float](repeating: 0, count: monoCount)
        mono.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, count: monoCount * 4)
        }

        // Resample 22050 -> 48000 (linear), upmix to interleaved stereo.
        let ratio = AppleJaxReceiver.resampleRatio
        // Last source index is monoCount - 1; output that fits is floor((monoCount-1)/ratio)+1
        let outFrames = max(1, Int(Double(monoCount - 1) / ratio) + 1)
        var stereo = [Float](repeating: 0, count: outFrames * 2)
        for j in 0..<outFrames {
            let srcPos = Double(j) * ratio
            let i0 = Int(srcPos)
            let i1 = min(i0 + 1, monoCount - 1)
            let frac = Float(srcPos - Double(i0))
            let s = mono[i0] * (1 - frac) + mono[i1] * frac
            stereo[j * 2] = s
            stereo[j * 2 + 1] = s
        }

        stereo.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                ringBuffer.write(base, frameCount: outFrames)
            }
        }
    }

    deinit {
        stop()
    }
}
