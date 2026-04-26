import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders the given payload as a QR code. CIFilter generates a tiny bitmap (~30×30 px),
/// so we transform it up by an integer factor and disable interpolation so it stays crisp
/// at TV resolution. The CIContext is built once and shared via a static; rebuilding it
/// per render churns several megabytes of allocation per frame.
struct QRCodeView: View {
    let payload: String
    var scale: CGFloat = 16

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        Group {
            if let image = render() {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("QR generation failed")
                    .foregroundStyle(.red)
            }
        }
    }

    private func render() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = Self.context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
