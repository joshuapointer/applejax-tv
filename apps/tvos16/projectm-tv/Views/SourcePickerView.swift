import SwiftUI
import MusicKit
import Darwin

/// First-run / idle screen for selecting audio source.
struct SourcePickerView: View {
    @EnvironmentObject private var appState: AppState
    var onSelectSource: ((SourceKind) -> Void)?

    @State private var musicAuthStatus: MusicAuthorization.Status = .notDetermined
    @State private var localIPv4: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                // Title
                VStack(spacing: 8) {
                    Text("projectM")
                        .font(.largeTitle)
                        .bold()
                    Text("Music Visualizer")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)

                // Source buttons
                VStack(spacing: 20) {
                    Button {
                        Task {
                            let authorized = await MusicKitSource.requestAuthorization()
                            if authorized {
                                onSelectSource?(.appleMusic)
                            } else {
                                musicAuthStatus = .denied
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "music.note")
                            Text("Apple Music")
                        }
                        .frame(maxWidth: 400)
                    }
                    .disabled(musicAuthStatus == .denied || musicAuthStatus == .restricted)

                    Button {
                        onSelectSource?(.localFile)
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            Text("Visualize (Idle)")
                        }
                        .frame(maxWidth: 400)
                    }

                    VStack(spacing: 6) {
                        Button {
                            onSelectSource?(.appleJax)
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("appleJax Companion")
                            }
                            .frame(maxWidth: 400)
                        }
                        // Surface the TV's IP+port directly so the iPhone setup
                        // is "look at the TV, type what you see" instead of
                        // "open Settings, dig through Network".
                        if let ip = localIPv4 {
                            Text("Connect iPhone to \(ip):9999")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospaced()
                        } else {
                            Text("(no Wi-Fi/Ethernet detected)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if musicAuthStatus == .denied {
                    Text("Apple Music access denied. Enable in Settings → Privacy → Media & Apple Music.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }

                Spacer()

                // About/Acknowledgements link
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Text("About & Licenses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
        }
        .task {
            musicAuthStatus = MusicAuthorization.currentStatus
            localIPv4 = Self.firstNonLoopbackIPv4()
        }
    }

    /// Walks the BSD `getifaddrs` chain and returns the first non-loopback IPv4
    /// address — typically the en0 (Ethernet) or en1 (Wi-Fi) interface on Apple TV.
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
                  addr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &hostBuf, socklen_t(hostBuf.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
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
