import SwiftUI

/// Big-target live performance surface: scene pads, tempo, macros and envelope hits.
struct PerformView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    private let pads = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: pads, spacing: 12) {
                        ForEach(Array(engine.project.scenes.enumerated()), id: \.element.id) { i, scene in
                            let active = scene.id == engine.project.activeSceneID
                            Button { engine.goToScene(scene.id) } label: {
                                VStack {
                                    Text(scene.name).font(.headline)
                                    Text("Pad \(i + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 90)
                                .background(RoundedRectangle(cornerRadius: 14).fill(active ? Color.pink.opacity(0.6) : Color.white.opacity(0.1)))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(scene.id == engine.transitionTargetID ? Color.yellow : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    TempoRow()

                    VStack(alignment: .leading) {
                        Text("Macros").font(.headline)
                        ForEach(0..<4, id: \.self) { i in
                            HStack {
                                Text("M\(i + 1)").frame(width: 32)
                                Slider(value: $engine.project.macros[i], in: 0...1)
                            }
                        }
                        Text("Map any parameter to a macro from its dial menu. Timeline automation drives macros during playback.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Button {
                        engine.triggerManualEnvelopes()
                    } label: {
                        Label("Hit (manual envelopes)", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    MetersPanel(meters: engine.meters)
                }
                .padding()
            }
            .navigationTitle("Perform")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct TempoRow: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack {
            Text("\(Int(engine.project.bpm)) BPM").font(.title2.monospacedDigit())
            Stepper("", value: $engine.project.bpm, in: 40...240, step: 1).labelsHidden()
            Spacer()
            BeatLight(meters: engine.meters)
            Button("Tap") { engine.tapTempo() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

struct BeatLight: View {
    @ObservedObject var meters: Meters
    var body: some View {
        Circle()
            .fill(meters.beat.truncatingRemainder(dividingBy: 1) < 0.2 ? Color.yellow : Color.gray.opacity(0.3))
            .frame(width: 20, height: 20)
    }
}

struct MetersPanel: View {
    @ObservedObject var meters: Meters

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inputs").font(.headline)
            LevelMeter(label: "Level", value: meters.audio.level)
            LevelMeter(label: "Bass", value: meters.audio.bass, tint: .red)
            LevelMeter(label: "Mid", value: meters.audio.mid, tint: .yellow)
            LevelMeter(label: "High", value: meters.audio.high, tint: .cyan)
            ForEach(Array(meters.lfo.enumerated()), id: \.offset) { i, v in
                LevelMeter(label: "LFO \(i + 1)", value: v, tint: .purple)
            }
            ForEach(Array(meters.envelope.enumerated()), id: \.offset) { i, v in
                LevelMeter(label: "Env \(i + 1)", value: v, tint: .orange)
            }
        }
    }
}
