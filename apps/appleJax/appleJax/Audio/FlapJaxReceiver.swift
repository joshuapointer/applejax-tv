import Foundation
import Darwin

/// UDP datagram receiver for the flapJax companion iPhone app.
///
/// Implementation note (v3): switched from `NWListener.udp` to a raw POSIX UDP socket
/// drained by a `DispatchSourceRead`. The Network-framework path was fundamentally
/// broken for sustained single-peer UDP receive — once the first datagram from a
/// given source-tuple was delivered, subsequent datagrams from the same iPhone got
/// rejected at the kernel with `EEXIST` ("nw_path_evaluator_create_flow_inner …
/// [17: File exists]"). Net effect: we received exactly one datagram per pairing
/// then went deaf. BSD sockets sidestep that whole flow-tracking mess and just
/// hand us every datagram as it arrives.
///
/// Wire protocol (per datagram):
///   bytes 0-3:  ASCII magic "APJX"
///   bytes 4-7:  uint32 LE  mono sample count
///   bytes 8..:  Float32 LE PCM, mono, 22050 Hz
///
/// Each datagram is independently parseable. We resample to 48 kHz stereo (linear,
/// mono → duplicated channels) and write into the shared `PCMRingBuffer`.
///
/// "Client connected" is derived from packet-arrival recency (≤ 5s gap = connected).
/// A `DispatchSourceTimer` polls the timestamp on the receiver queue and fires
/// `onClientChange` on transitions, driving the QR pairing overlay.
final class FlapJaxReceiver: AudioSource {
    static let defaultPort: UInt16 = 9999
    private static let inSampleRate: Double = 22050
    private static let outSampleRate: Double = 48000
    private static let resampleRatio: Double = inSampleRate / outSampleRate
    private static let magic: [UInt8] = [0x41, 0x50, 0x4A, 0x58] // "APJX"
    private static let headerSize: Int = 8
    /// 5s of no packets = consider iPhone gone. Wi-Fi blips can lose ~30 consecutive
    /// 46ms datagrams without it being a real disconnect; 5s comfortably absorbs that.
    private static let connectedTimeoutSeconds: TimeInterval = 5.0

    private let ringBuffer: PCMRingBuffer
    private let port: UInt16
    private let queue = DispatchQueue(label: "flapjax.receiver", qos: .userInteractive)

    /// Fired on the receiver's `queue` whenever client-connected state transitions.
    /// Hop to main before touching SwiftUI state.
    var onClientChange: ((Bool) -> Void)?

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var clientTimer: DispatchSourceTimer?
    private var lastPacketAt: TimeInterval = 0
    private var hasClientFlag = false

    // Pre-allocated receive buffer — UDP max payload is 64 KiB but our datagrams are
    // ~4 KiB. 16 KiB is a safe ceiling that covers any iPhone-side chunk size.
    private static let recvBufferSize = 16 * 1024
    private var recvBuffer: UnsafeMutablePointer<UInt8>

    // 1Hz diagnostic accumulators — touched only on `queue`, no lock needed.
    private var bytesIn: Int = 0
    private var datagramsParsed: Int = 0
    private var pcmFramesEmitted: Int = 0
    private var diagWindowStart: TimeInterval = 0

    #if DEBUG
    /// Snapshot of the most recent UDP datagram for the on-screen debug overlay.
    struct DebugDatagram {
        let receivedAt: TimeInterval
        let totalBytes: Int
        let sampleCount: UInt32
        let headerHex: String       // first 32 bytes formatted as "ab cd ef …"
        let firstSamples: [Float]   // first ≤6 decoded mono samples
    }
    private var debugLock = os_unfair_lock()
    private var _debugRing: [DebugDatagram] = []
    private let debugRingCap = 8

    func debugSnapshot() -> [DebugDatagram] {
        os_unfair_lock_lock(&debugLock); defer { os_unfair_lock_unlock(&debugLock) }
        return _debugRing
    }
    #endif

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
        return NowPlayingInfo(title: "flapJax",
                              artist: clientDescription,
                              album: "Live PCM (UDP)",
                              bpm: nil)
    }

    init(ringBuffer: PCMRingBuffer, port: UInt16 = FlapJaxReceiver.defaultPort) {
        self.ringBuffer = ringBuffer
        self.port = port
        self.recvBuffer = .allocate(capacity: Self.recvBufferSize)
    }

    // MARK: - AudioSource lifecycle

    func start() throws {
        guard socketFD < 0 else { return }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            let err = errno
            audioLogger.error("FlapJaxReceiver socket() failed: errno=\(err, privacy: .public)")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        // Allow rapid relaunch — old socket may still be in TIME_WAIT briefly.
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bump the kernel receive buffer so a brief CPU stall on the render thread
        // can't drop datagrams that have already arrived at the NIC.
        var rcvBuf: Int32 = 256 * 1024
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        // Bind to 0.0.0.0:port (any interface).
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian
        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            audioLogger.error("FlapJaxReceiver bind() failed: errno=\(err, privacy: .public)")
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        socketFD = fd

        // Async drain on the receiver queue. The read source fires whenever there
        // are bytes in the kernel buffer; we recvfrom in a loop until EAGAIN to
        // service all queued datagrams in one wakeup.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        readSource = source

        setIsPlaying(true)
        setListenPort(port)
        audioLogger.notice("FlapJaxReceiver UDP listening on \(self.port, privacy: .public) (BSD socket)")
        startClientTimeoutMonitor()
    }

    func pause() { stop() }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.readSource?.cancel()  // closes FD via cancel handler
            self.readSource = nil
            self.socketFD = -1
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

    // MARK: - Datagram drain

    /// Called from the DispatchSource on the receiver queue. Drains the kernel
    /// buffer in a non-blocking loop so multiple queued datagrams are serviced in
    /// one wakeup; otherwise we'd spin one wakeup per packet.
    private func drainSocket() {
        let fd = socketFD
        guard fd >= 0 else { return }

        var fromAddr = sockaddr_storage()
        let addrSize = socklen_t(MemoryLayout<sockaddr_storage>.size)

        while true {
            var fromLen = addrSize
            let n = withUnsafeMutablePointer(to: &fromAddr) { addrPtr -> Int in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.recvfrom(fd, recvBuffer, Self.recvBufferSize, Int32(MSG_DONTWAIT), saPtr, &fromLen)
                }
            }
            if n <= 0 {
                let err = errno
                if n < 0 && err != EAGAIN && err != EWOULDBLOCK && err != EINTR {
                    audioLogger.error("FlapJaxReceiver recvfrom errno=\(err, privacy: .public)")
                }
                break
            }
            let data = Data(bytes: recvBuffer, count: n)
            let source = describeSockaddr(&fromAddr)
            handleDatagram(data, sourceDescription: source)
        }
    }

    // MARK: - Datagram parse + ingest

    private func handleDatagram(_ data: Data, sourceDescription source: String) {
        bytesIn += data.count

        // Validate magic + length header.
        guard data.count >= Self.headerSize else { return }
        let m = FlapJaxReceiver.magic
        guard data[0] == m[0], data[1] == m[1], data[2] == m[2], data[3] == m[3] else {
            return
        }
        let sampleCount: UInt32 = (UInt32(data[4])
            | (UInt32(data[5]) << 8)
            | (UInt32(data[6]) << 16)
            | (UInt32(data[7]) << 24))
        let payloadBytes = Int(sampleCount) * 4
        guard payloadBytes > 0,
              sampleCount <= 8192,
              data.count >= Self.headerSize + payloadBytes else {
            return
        }

        let payload = data.subdata(in: Self.headerSize..<(Self.headerSize + payloadBytes))
        ingest(monoFloat32LE: payload)

        datagramsParsed += 1
        lastPacketAt = CFAbsoluteTimeGetCurrent()

        #if DEBUG
        recordDebugDatagram(data, payload: payload, sampleCount: sampleCount, receivedAt: lastPacketAt)
        #endif

        if !hasClientFlag {
            hasClientFlag = true
            setClientDescription(source)
            audioLogger.notice("FlapJaxReceiver UDP first packet from \(source, privacy: .public)")
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

        let ratio = FlapJaxReceiver.resampleRatio
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
                audioLogger.notice("FlapJaxReceiver UDP client timed out (no packet for \(String(format: "%.2f", gap), privacy: .public)s)")
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
        audioLogger.notice("FlapJax UDP bytes=\(self.bytesIn, privacy: .public) datagrams=\(self.datagramsParsed, privacy: .public) pcmOut=\(self.pcmFramesEmitted, privacy: .public) in \(String(format: "%.2f", elapsed), privacy: .public)s")
        bytesIn = 0
        datagramsParsed = 0
        pcmFramesEmitted = 0
        diagWindowStart = now
    }

    private func describeSockaddr(_ addr: inout sockaddr_storage) -> String {
        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var portBuf = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        // Cache ss_len outside the inout pointer scope — Swift's exclusive-access
        // rules forbid reading `addr.ss_len` inside `withUnsafePointer(to: &addr)`.
        let addrLen = socklen_t(addr.ss_len)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getnameinfo(saPtr, addrLen,
                            &hostBuf, socklen_t(hostBuf.count),
                            &portBuf, socklen_t(portBuf.count),
                            NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard result == 0 else { return "(unknown)" }
        return "\(String(cString: hostBuf)):\(String(cString: portBuf))"
    }

    #if DEBUG
    private func recordDebugDatagram(_ data: Data, payload: Data, sampleCount: UInt32, receivedAt: TimeInterval) {
        let hexCount = min(32, data.count)
        var hex = ""
        hex.reserveCapacity(hexCount * 3)
        for i in 0..<hexCount {
            if i > 0 { hex += " " }
            hex += String(format: "%02x", data[i])
        }
        let sampleCountToDecode = min(6, payload.count / 4)
        var samples = [Float](repeating: 0, count: sampleCountToDecode)
        if sampleCountToDecode > 0 {
            samples.withUnsafeMutableBytes { dst in
                payload.copyBytes(to: dst, count: sampleCountToDecode * 4)
            }
        }
        let entry = DebugDatagram(
            receivedAt: receivedAt,
            totalBytes: data.count,
            sampleCount: sampleCount,
            headerHex: hex,
            firstSamples: samples
        )
        os_unfair_lock_lock(&debugLock)
        _debugRing.append(entry)
        if _debugRing.count > debugRingCap {
            _debugRing.removeFirst(_debugRing.count - debugRingCap)
        }
        os_unfair_lock_unlock(&debugLock)
    }
    #endif

    deinit {
        stop()
        recvBuffer.deallocate()
    }
}
