import SwiftUI

/// Inputs and modulation setup: tempo, LFOs, envelopes, audio, MIDI, tracking, output.
struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Tempo") { TempoRow() }

                Section("LFOs (beat-synced)") {
                    ForEach(engine.project.lfos.indices, id: \.self) { i in
                        HStack {
                            Text("LFO \(i + 1)").frame(width: 56, alignment: .leading)
                            Picker("", selection: $engine.project.lfos[i].shape) {
                                ForEach(LFOShape.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            Picker("", selection: $engine.project.lfos[i].rateBeats) {
                                ForEach([0.25, 0.5, 1, 2, 4, 8, 16, 32], id: \.self) { b in
                                    Text(b < 1 ? "1/\(Int(1 / b)) beat" : "\(Int(b)) beat\(b == 1 ? "" : "s")").tag(b)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }

                Section("Envelopes") {
                    ForEach(engine.project.envelopes.indices, id: \.self) { i in
                        VStack(alignment: .leading) {
                            Picker("Envelope \(i + 1) trigger", selection: $engine.project.envelopes[i].trigger) {
                                ForEach(EnvelopeTrigger.allCases) { Text($0.rawValue).tag($0) }
                            }
                            LabeledContent("Attack") { Slider(value: $engine.project.envelopes[i].attack, in: 0...1) }
                            LabeledContent("Decay") { Slider(value: $engine.project.envelopes[i].decay, in: 0.05...3) }
                        }
                    }
                }

                Section("Audio") {
                    Toggle("React to microphone", isOn: $engine.audioInputEnabled)
                    MetersPanel(meters: engine.meters)
                }

                Section {
                    let names = engine.midi.sourceNames
                    if names.isEmpty {
                        Text("No MIDI devices. Connect a controller over USB, Bluetooth or the network.").foregroundStyle(.secondary)
                    } else {
                        ForEach(names, id: \.self) { Label($0, systemImage: "pianokeys") }
                    }
                    Toggle("Notes from C1 switch scenes", isOn: $engine.midiNotesSwitchScenes)
                    if engine.midiLearnActive {
                        Label("Listening — move a knob or fader…", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.pink)
                    }
                } header: {
                    Text("MIDI")
                } footer: {
                    Text("Map a knob from any parameter's dial menu with \u{201C}MIDI learn\u{201D}.")
                }

                Section("Hand & face tracking") {
                    Toggle("Track with camera", isOn: $engine.trackingEnabled)
                    TrackingReadout(meters: engine.meters)
                }

                Section("Output") {
                    LabeledContent("Display", value: engine.externalDisplayConnected ? "External (HDMI / AirPlay)" : "Preview only")
                    LabeledContent("Resolution", value: "\(engine.renderer.outputSize.x) × \(engine.renderer.outputSize.y)")
                    Text("Connect a projector with a USB-C or Lightning HDMI adapter, or choose AirPlay in Control Center. The projector shows the clean output; controls stay on this screen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Inputs & output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct TrackingReadout: View {
    @ObservedObject var meters: Meters
    var body: some View {
        LevelMeter(label: "Hand X", value: meters.tracking.handX, tint: .mint)
        LevelMeter(label: "Hand Y", value: meters.tracking.handY, tint: .mint)
        LevelMeter(label: "Pinch", value: meters.tracking.pinch, tint: .teal)
        LevelMeter(label: "Face X", value: meters.tracking.faceX, tint: .indigo)
        LevelMeter(label: "Mouth", value: meters.tracking.mouthOpen, tint: .pink)
    }
}
