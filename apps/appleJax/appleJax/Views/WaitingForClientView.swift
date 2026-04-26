import SwiftUI
import Darwin

/// Full-screen "Pair with iPhone" overlay. Shown on launch and whenever no FlapJax
/// client is connected. Encodes the TV's local IPv4 + listen port as both a QR code
/// (`applejax://<host>:<port>`) and human-readable text so users can scan or type.
struct WaitingForClientView: View {
    var port: UInt16 = 9999
    @State private var localIPv4: String? = nil

    private var pairURL: String {
        "applejax://\(localIPv4 ?? "0.0.0.0"):\(port)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 6) {
                    Text("appleJax")
                        .font(.system(size: 60, weight: .bold))
                    Text("Scan with the flapJax companion app on your iPhone")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if localIPv4 != nil {
                    QRCodeView(payload: pairURL)
                        .frame(width: 420, height: 420)
                        .padding(28)
                        .background(Color.white)
                        .cornerRadius(24)

                    Text("\(localIPv4!):\(port)")
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connect this Apple TV to Wi-Fi or Ethernet to pair.")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 480, height: 480)
                }
            }
            .padding(60)
        }
        .task {
            // Refresh the IP once at appear, then re-check periodically until we find one
            // (handles the case where Wi-Fi joins after launch).
            for _ in 0..<30 {
                let ip = Self.firstNonLoopbackIPv4()
                if ip != nil {
                    localIPv4 = ip
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            localIPv4 = Self.firstNonLoopbackIPv4()
        }
    }

    /// Walks `getifaddrs` and returns the first non-loopback IPv4 address from an `enX`
    /// interface (Wi-Fi or Ethernet on Apple TV), falling back to any other non-loopback.
    private static func firstNonLoopbackIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var bestEn: String? = nil
        var fallback: String? = nil
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &hostBuf, socklen_t(hostBuf.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostBuf)
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("en") {
                bestEn = bestEn ?? ip
            } else if fallback == nil {
                fallback = ip
            }
        }
        return bestEn ?? fallback
    }
}
