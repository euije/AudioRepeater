import SwiftUI

enum PlaybackSheet: String, Identifiable {
    case equalizer, dynamics, recordings
    var id: String { rawValue }
}

struct PlaybackEffectEditor: View {
    @Binding var settings: PlaybackSettings
    let sheet: PlaybackSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if sheet == .equalizer {
                    Section {
                        ForEach(PlaybackSettings.equalizerFrequencies.indices, id: \.self) { index in
                            parameter("\(Int(PlaybackSettings.equalizerFrequencies[index])) Hz",
                                value: $settings.equalizerGains[index], range: -15...15, unit: "dB")
                        }
                        Button("Reset EQ") { settings.equalizerGains = [0, 0, 0, 0, 0] }
                    } footer: {
                        Text("Five parametric bands, one-octave bandwidth. Changes apply on the next playback.")
                    }
                } else {
                    Section {
                        parameter("Threshold", value: $settings.dynamics.thresholdDB, range: -40...0, unit: "dB")
                        parameter("Headroom", value: $settings.dynamics.headroomDB, range: 0.1...40, unit: "dB")
                        parameter("Attack", value: $settings.dynamics.attackMS, range: 0.1...200, unit: "ms")
                        parameter("Release", value: $settings.dynamics.releaseMS, range: 10...3000, unit: "ms")
                        parameter("Master gain", value: $settings.dynamics.masterGainDB, range: -40...24, unit: "dB")
                        Toggle("Peak limiter", isOn: $settings.dynamics.peakLimiter)
                        Button("Reset dynamics") { settings.dynamics = DynamicsSettings() }
                    } footer: {
                        Text("Apple's broadband Dynamics Processor and optional Peak Limiter. Headroom controls the compression curve. These parameters differ from Android's multiband Dynamics Processing.")
                    }
                }
            }
            .navigationTitle(sheet == .equalizer ? "Equalizer" : "Dynamics Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func parameter(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f") \(unit)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}

struct RecordingLibraryView: View {
    let onAdd: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recordings: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if recordings.isEmpty {
                    Text("No recordings yet").foregroundStyle(.secondary)
                }
                ForEach(recordings, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(url.lastPathComponent).font(.subheadline).textSelection(.enabled)
                        HStack {
                            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            if url.pathExtension.lowercased() == "wav" {
                                Spacer()
                                Button("Add to queue") { onAdd(url); dismiss() }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { recordings = try LibraryStore().recordings() }
                catch { errorMessage = error.localizedDescription }
            }
            .alert("Could not open recordings", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }
}
