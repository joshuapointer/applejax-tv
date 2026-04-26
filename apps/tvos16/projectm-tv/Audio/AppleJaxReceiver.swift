import Foundation
import Network

/// UDP datagram receiver for the appleJax Control companion iPhone app.
///
/// Switched from TCP to UDP so that real-time PCM is **drop-tolerant** instead of
/// **stall-prone**: TCP backpressure (which we hit constantly on Wi-Fi) head-of-lines
/// every later byte until the kernel's send buffer drains, producing the bursty
/// 1.6s-then-silence pattern we saw in field testing. UDP just drops the datagram
/// on the floor, the next one arrives ~46 ms later, and the visualizer never stalls.
///
/// Wire protocol (per datagram, max ~4 KB + tiny header → typically 3 IP fragments
/// on a 1500-MTU LAN; no fragmentation if iPhone splits chunks smaller):
///
///   bytes 0-3:  ASCII magic "APJX"
///   bytes 4-7:  uint32 LE  mono sample count
///   bytes 8..:  Float32 LE PCM, mono, 22050 Hz
///
/// Each datagram is independently parseable — no cross-packet state. We resample to
/// 48 kHz stereo (linear, mono → duplicated channels) and write into the shared
/// `PCMRingBuffer` exactly the same way the prior TCP path did.
///
/// "Client connected" is derived from packet-arrival recency (≤ 1.5s gap = connected),
/// not from a connection handshake. A DispatchSourceTimer polls the timestamp on the
/// receiver queue and fires `onClientChange` on transitions.
final class AppleJaxReceiver: AudioSource {
    static let defaultPort: UInt16 = 9999
    private static let inSampleRate: Double = 22050
    private static let outSampleRate: Double = 48000
    private static let resampleRatio: Double = inSampleRate / outSampleRate
    private static let magic: [UInt8] = [0x41, 0x50, 0x4A, 0x58] // "APJX"
    private static let headerSize: Int = 8
    private static let connectedTimeoutSeconds: TimeInterval = 1.5

    private let ringBuffer: PCMRingBuffer
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "applejax.receiver", qos: .userInteractive)

    /// Fired on the receiver's `queue` whenever client-connected state transitions.
    /// Used by the UI to show/hide the QR pairing overlay. Hop to main before touching
    /// SwiftUI state.
    var onClientChange: ((Bool) -> Void)?

    private var listener: NWListener?
    /// Per-source flows. NWListener .udp creates a virtual NWConnection for each
    /// unique src-IP/src-port pair; we hold them in a set so they aren't released
    /// after the receive callback returns and so we can cancel them in `stop()`.
    private var flows: [ObjectIdentifier: NWConnection] = [:]
    private var clientTimer: DispatchSourceTimer?
    private var lastPacketAt: TimeInterval = 0
    private var hasClientFlag = false

    // 1Hz diagnostic accumulators — touched only on `queue`, no lock needed.
    private var bytesIn: Int = 0
    private var datagramsParsed: Int = 0
    private var pcmFramesEmitted: Int = 0
    private var diagWindowStart: TimeInterval = 0

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
                              album: "Live PCM (UDP)",
                              bpm: nil)
    }

    init(ringBuffer: PCMRingBuffer, port: UInt16 = AppleJaxReceiver.defaultPort) {
        self.ringBuffer = ringBuffer
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: AppleJaxReceiver.defaultPort)!
    }

    // MARK: - AudioSource

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let p = listener.port?.rawValue ?? 0
                self.setListenPort(p)
                audioLogger.notice("AppleJaxReceiver UDP listening on \(p)")
            case .failed(let err):
                audioLogger.error("AppleJaxReceiver UDP listener failed: \(err.localizedDescription)")
            case .cancelled:
                audioLogger.info("AppleJaxReceiver UDP listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.adopt(flow: conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        setIsPlaying(true)
        startClientTimeoutMonitor()
    }

    func pause() { stop() }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, conn) in self.flows {
                conn.cancel()
            }
            self.flows.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.clientTimer?.cancel()
            self.clientTimer = nil
            self.setListenPort(0)
            self.setClientDescription("(no client)")
            if self.hasClientFlag {
                self.hasClientFlag = false
                self.onClientChange?(false)
            }
        }
        setIsPlaying(false)
    }

    // MARK: - UDP flow lifecycle

    private func adopt(flow conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        flows[id] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.receiveLoop(on: conn)
            case .failed, .cancelled:
                self.flows.removeValue(forKey: ObjectIdentifier(conn))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop(on conn: NWConnection) {
        // receiveMessage gives us exactly one UDP datagram per call — boundary-preserving.
        // For TCP this would have to be `receive(min:max:)` with manual reframing.
        conn.receiveMessage { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn else { return }
            if let data, !data.isEmpty {
                self.handleDatagram(data, source: conn.endpoint)
            }
            if let error {
                audioLogger.error("AppleJaxReceiver flow receive error: \(error.localizedDescription)")
                conn.cancel()
                return
            }
            if isComplete {
                conn.cancel()
                return
            }
            self.receiveLoop(on: conn)
        }
    }

    // MARK: - Datagram parse + ingest

    private func handleDatagram(_ data: Data, source endpoint: NWEndpoint) {
        bytesIn += data.count

        // Validate magic + length header.
        guard data.count >= Self.headerSize else { return }
        let m = AppleJaxReceiver.magic
        guard data[data.startIndex]     == m[0],
              data[data.startIndex + 1] == m[1],
              data[data.startIndex + 2] == m[2],
              data[data.startIndex + 3] == m[3] else {
            // Stray non-APJX datagram (port scanner, mDNS bleed, etc) — ignore.
            return
        }
        let lenBase = data.startIndex + 4
        let sampleCount: UInt32 = (UInt32(data[lenBase])
            | (UInt32(data[lenBase + 1]) << 8)
            | (UInt32(data[lenBase + 2]) << 16)
            | (UInt32(data[lenBase + 3]) << 24))
        let payloadBytes = Int(sampleCount) * 4
        guard payloadBytes > 0,
              sampleCount <= 8192,                       // sanity cap
              data.count >= Self.headerSize + payloadBytes else {
            return
        }

        let payload = data.subdata(in: (data.startIndex + Self.headerSize)..<(data.startIndex + Self.headerSize + payloadBytes))
        ingest(monoFloat32LE: payload)

        datagramsParsed += 1
        lastPacketAt = CFAbsoluteTimeGetCurrent()
        if !hasClientFlag {
            hasClientFlag = true
            setClientDescription(describe(endpoint: endpoint))
            audioLogger.notice("AppleJaxReceiver UDP first packet from \(self.describe(endpoint: endpoint), privacy: .public)")
            onClientChange?(true)
        }
        emitDiagnosticIfDue()
    }

    private func ingest(monoFloat32LE data: Data) {
        let monoCount = data.count / 4
        if monoCount == 0 { return }

        var mono = [Float](repeating: 0, count: monoCount)
        mono.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, count: monoCount * 4)
        }

        // 22050 → 48000 linear resample, mono → interleaved stereo (L = R).
        let ratio = AppleJaxReceiver.resampleRatio
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
                let written = ringBuffer.write(base, frameCount: outFrames)
                pcmFramesEmitted += written
            }
        }
    }

    // MARK: - Client-connected timeout

    /// Polls every 0.5 s on the receiver queue. If we haven't seen a packet in
    /// `connectedTimeoutSeconds`, transition to "no client" so the UI re-shows the QR.
    private func startClientTimeoutMonitor() {
        clientTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.hasClientFlag else { return }
            let gap = CFAbsoluteTimeGetCurrent() - self.lastPacketAt
            if gap > Self.connectedTimeoutSeconds {
                self.hasClientFlag = false
                self.setClientDescription("(no client)")
                audioLogger.notice("AppleJaxReceiver UDP client timed out (no packet for \(String(format: "%.2f", gap))s)")
                self.onClientChange?(false)
            }
        }
        timer.resume()
        clientTimer = timer
    }

    private func emitDiagnosticIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        if diagWindowStart == 0 {
            diagWindowStart = now
            return
        }
        let elapsed = now - diagWindowStart
        guard elapsed >= 1.0 else { return }
        audioLogger.notice("AppleJax UDP bytes=\(self.bytesIn) datagrams=\(self.datagramsParsed) pcmOut=\(self.pcmFramesEmitted) in \(String(format: "%.2f", elapsed))s")
        bytesIn = 0
        datagramsParsed = 0
        pcmFramesEmitted = 0
        diagWindowStart = now
    }

    private func describe(endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let p): return "\(host):\(p)"
        case .service(let name, _, _, _): return name
        case .url(let url): return url.absoluteString
        case .unix(let path): return path
        case .opaque: return "(opaque)"
        @unknown default: return "(unknown)"
        }
    }

    deinit {
        stop()
    }
}
