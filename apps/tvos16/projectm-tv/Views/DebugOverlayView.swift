#if DEBUG
import SwiftUI

/// Corner box that renders the most recent raw UDP datagrams from the iPhone for
/// protocol-level debugging. Toggled by double-tapping the Siri Remote select button.
/// Lives only in DEBUG builds — `#if DEBUG` at file scope keeps the symbol out of
/// release entirely. Polls `AppleJaxReceiver.debugSnapshot()` at 10 Hz; the receiver
/// keeps a small lock-protected ring of recent entries so this read is cheap.
struct DebugOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @State private var snapshot: [AppleJaxReceiver.DebugDatagram] = []

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.appleJaxClientConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("UDP DEBUG")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
                Text("\(snapshot.count) recent")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if snapshot.isEmpty {
                Text("(no datagrams received)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                // Most recent first.
                ForEach(Array(snapshot.reversed().enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(timestampString(entry.receivedAt))  \(entry.totalBytes)B  sc=\(entry.sampleCount)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(entry.headerHex)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.55))
                            .lineLimit(2)
                        if !entry.firstSamples.isEmpty {
                            Text(entry.firstSamples.map { String(format: "%+.3f", $0) }.joined(separator: " "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Text("Double-tap select to dismiss")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(12)
        .frame(width: 520, alignment: .leading)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .onReceive(timer) { _ in
            snapshot = appState.appleJaxReceiver?.debugSnapshot() ?? []
        }
    }

    private func timestampString(_ t: TimeInterval) -> String {
        // CFAbsoluteTime epoch is 2001-01-01; convert via Date.
        let date = Date(timeIntervalSinceReferenceDate: t)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
#endif
