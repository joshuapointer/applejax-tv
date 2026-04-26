import SwiftUI

/// Displays license and attribution information.
struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("About projectM TV")
                    .font(.title2)
                    .bold()

                Group {
                    Text("projectM Library")
                        .font(.headline)
                    Text("projectM is an open-source Milkdrop-compatible music visualizer library.")
                    Text("License: LGPL-2.1")
                    Text("Source: https://github.com/projectM-visualizer/projectm")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Group {
                    Text("Apple Music Limitation")
                        .font(.headline)
                    Text("Due to DRM restrictions, Apple Music mode uses a synthetic beat-grid generator rather than tapping the actual audio stream. The visualizer reacts to estimated BPM and energy, not the real audio waveform.")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Group {
                    Text("Preset Pack")
                        .font(.headline)
                    Text("Bundled presets are from the projectM 'Cream of the Crop' collection. See the included LICENSE.md for redistribution terms.")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 40)
            }
            .padding(40)
        }
        .navigationTitle("Acknowledgements")
    }
}
