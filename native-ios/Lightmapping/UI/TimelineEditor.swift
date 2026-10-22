import SwiftUI
import UniformTypeIdentifiers

/// Arrange scenes on a timeline over an audio track, with macro automation lanes.
struct TimelineEditor: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var importingAudio = false

    private var timeline: Binding<Timeline> { $engine.project.timeline }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    overview.frame(height: 56).listRowInsets(EdgeInsets())
                    HStack {
                        Button {
                            engine.isTimelinePlaying ? engine.stopTimeline() : engine.playTimeline()
                        } label: {
                            Label(engine.isTimelinePlaying ? "Stop" : "Play show", systemImage: engine.isTimelinePlaying ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.project.timeline.clips.isEmpty)
                        Spacer()
                        Text(format(engine.timelinePosition) + " / " + format(engine.project.timeline.duration))
                            .font(.callout.monospacedDigit())
                    }
                }

                Section("Audio track") {
                    if engine.project.timeline.audioAssetID != nil {
                        Label("Audio attached", systemImage: "music.note")
                        Button("Remove audio", role: .destructive) { timeline.wrappedValue.audioAssetID = nil }
                    }
                    Button("Choose audio file…", systemImage: "waveform") { importingAudio = true }
                }

                Section("Clips") {
                    ForEach(timeline.clips) { $clip in
                        VStack(alignment: .leading) {
                            Picker("Scene", selection: $clip.sceneID) {
                                ForEach(engine.project.scenes) { Text($0.name).tag($0.id) }
                            }
                            Stepper("Start \(format(clip.start))", value: $clip.start, in: 0...3600, step: 0.5)
                            Stepper("Length \(format(clip.duration))", value: $clip.duration, in: 0.5...600, step: 0.5)
                            HStack {
                                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(clip) }
                                Button("Snap to bar", systemImage: "metronome") { snap(clip.id) }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .onDelete { timeline.wrappedValue.clips.remove(atOffsets: $0) }
                    Button("Add clip", systemImage: "plus") { addClip() }
                }

                Section("Automation") {
                    ForEach(timeline.automation) { $lane in
                        VStack(alignment: .leading) {
                            Picker("Drives", selection: $lane.macroIndex) {
                                ForEach(0..<4, id: \.self) { Text("Macro \($0 + 1)").tag($0) }
                            }
                            ForEach(Array(lane.keyframes.enumerated()), id: \.offset) { i, k in
                                HStack {
                                    Text(format(k.time)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .leading)
                                    Slider(value: $lane.keyframes[i].value, in: 0...1)
                                    Button(role: .destructive) { $lane.wrappedValue.keyframes.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                            Button("Keyframe at playhead", systemImage: "diamond") {
                                let t = engine.timelinePosition
                                let v = engine.project.macros.indices.contains(lane.macroIndex) ? engine.project.macros[lane.macroIndex] : 0
                                $lane.wrappedValue.keyframes.append(AutomationKeyframe(time: t, value: v))
                                $lane.wrappedValue.keyframes.sort { $0.time < $1.time }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { timeline.wrappedValue.automation.remove(atOffsets: $0) }
                    Button("Add lane", systemImage: "plus") {
                        timeline.wrappedValue.automation.append(AutomationLane(macroIndex: timeline.wrappedValue.automation.count % 4))
                    }
                }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result, let id = try? ProjectStore.shared.importAsset(from: url) {
                    timeline.wrappedValue.audioAssetID = id
                }
            }
        }
    }

    private var overview: some View {
        GeometryReader { g in
            let total = max(engine.project.timeline.duration, 1)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.05))
                ForEach(engine.project.timeline.clips) { clip in
                    let name = engine.project.scenes.first { $0.id == clip.sceneID }?.name ?? "?"
                    let hue = Double(abs(clip.sceneID.hashValue % 360)) / 360
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hue: hue, saturation: 0.6, brightness: 0.7))
                        .overlay(Text(name).font(.caption2).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                        .frame(width: max(4, g.size.width * clip.duration / total), height: g.size.height - 12)
                        .offset(x: g.size.width * clip.start / total, y: 6)
                }
                Rectangle().fill(Color.yellow).frame(width: 2)
                    .offset(x: g.size.width * min(engine.timelinePosition / total, 1))
            }
        }
    }

    private func addClip() {
        let start = engine.project.timeline.duration
        let fourBars = 16 * 60 / engine.project.bpm
        let sceneID = engine.project.activeSceneID ?? engine.project.scenes[0].id
        timeline.wrappedValue.clips.append(TimelineClip(sceneID: sceneID, start: start, duration: fourBars))
    }

    private func duplicate(_ clip: TimelineClip) {
        var copy = clip
        copy.id = UUID()
        copy.start = engine.project.timeline.duration
        timeline.wrappedValue.clips.append(copy)
    }

    private func snap(_ id: UUID) {
        guard let i = engine.project.timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        let bar = 4 * 60 / engine.project.bpm
        var c = engine.project.timeline.clips[i]
        c.start = (c.start / bar).rounded() * bar
        c.duration = max(bar, (c.duration / bar).rounded() * bar)
        timeline.wrappedValue.clips[i] = c
    }

    private func format(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}
