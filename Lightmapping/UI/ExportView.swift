import MultipeerConnectivity
import SwiftUI

struct ExportView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var link = LinkService(role: .sender)

    @State private var options = ExportOptions()
    @State private var progress: Double?
    @State private var exported: URL?
    @State private var message: String?
    @State private var exporter: ShowExporter?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $options.resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Frame rate", selection: $options.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    if engine.project.timeline.clips.isEmpty {
                        Stepper("Length \(Int(options.fallbackDuration)) s (current scene)", value: $options.fallbackDuration, in: 5...600, step: 5)
                    } else {
                        LabeledContent("Length", value: "\(Int(engine.project.timeline.duration)) s (timeline)")
                    }
                    Toggle("Include audio track", isOn: $options.includeAudio)
                        .disabled(engine.project.timeline.audioAssetID == nil)
                } footer: {
                    Text("Renders the mapped output exactly as the projector sees it. Audio-reactive visuals follow the timeline's audio track.")
                }

                Section {
                    if let progress {
                        ProgressView(value: progress) { Text("Rendering… \(Int(progress * 100))%") }
                        Button("Cancel", role: .destructive) { exporter?.cancel() }
                    } else {
                        Button("Export show", systemImage: "film.stack") { startExport() }
                    }
                }

                if let exported {
                    Section("Finished") {
                        Text(exported.lastPathComponent).font(.caption)
                        Button("Save to Photos", systemImage: "photo.badge.plus") {
                            Task {
                                do { try await ShowExporter.saveToPhotos(exported); message = "Saved to Photos." }
                                catch { message = error.localizedDescription }
                            }
                        }
                        ShareLink(item: exported) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }

                    Section {
                        if link.peers.isEmpty {
                            Label("Open Receiver mode on another device on the same network.", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(link.peers, id: \.self) { peer in
                            HStack {
                                Text(peer.displayName)
                                Spacer()
                                if link.connected.contains(peer) {
                                    Button("Send") { link.send(exported, to: peer) { _ in } }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("Connect") { link.connect(peer) }.buttonStyle(.bordered)
                                }
                            }
                        }
                        if let p = link.transferProgress { ProgressView(value: p) }
                        Text(link.status).font(.caption).foregroundStyle(.secondary)
                    } header: {
                        Text("Send to receiver")
                    } footer: {
                        Text("The receiver saves the show and loops it on its own display, so you can close the app and take your phone.")
                    }
                }

                if let message { Text(message).font(.callout) }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { link.start() }
            .onDisappear { link.stop() }
        }
    }

    private func startExport() {
        let project = engine.project
        let exp = ShowExporter()
        exporter = exp
        progress = 0
        exported = nil
        message = nil
        let opts = options
        Task {
            do {
                let url = try await Task.detached {
                    try await exp.export(project, options: opts) { p in Task { @MainActor in progress = p } }
                }.value
                exported = url
            } catch is CancellationError {
                message = "Export cancelled."
            } catch {
                message = error.localizedDescription
            }
            progress = nil
        }
    }
}
