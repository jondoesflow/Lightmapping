import SwiftUI

struct ProjectBrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var projects: [Project] = []
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { newName = "Projection \(projects.count + 1)"; naming = true } label: {
                        Label("New project", systemImage: "plus.rectangle.on.rectangle")
                    }
                    Button { model.open(Self.demoProject()) } label: {
                        Label("Start from a demo", systemImage: "sparkles.tv")
                    }
                }
                Section("Projects") {
                    if projects.isEmpty { Text("No saved projects yet.").foregroundStyle(.secondary) }
                    ForEach(projects) { p in
                        Button { model.open(p) } label: {
                            VStack(alignment: .leading) {
                                Text(p.name).font(.headline)
                                Text("\(p.surfaces.count) surfaces · \(p.scenes.count) scenes · \(p.modifiedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        idx.forEach { ProjectStore.shared.delete(projects[$0]) }
                        projects.remove(atOffsets: idx)
                    }
                }
                Section {
                    Button { model.receiverMode = true } label: {
                        Label("Receiver mode", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Use a spare iPhone, iPad or iPod connected to the projector as a receiver. Send it a finished show and it loops on its own.")
                }
            }
            .navigationTitle("Lightmapping")
            .onAppear { projects = ProjectStore.shared.listProjects() }
            .alert("New project", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let p = Project(name: newName.isEmpty ? "Untitled" : newName)
                    try? ProjectStore.shared.save(p)
                    model.open(p)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// A ready-to-map starter: a wall, a box and a window across two scenes.
    static func demoProject() -> Project {
        var p = Project(name: "Demo house")
        let wall = Surface(name: "Wall", shape: .quad, mesh: .quad(SIMD2(0.05, 0.1), SIMD2(0.45, 0.14), SIMD2(0.05, 0.9), SIMD2(0.45, 0.86)))
        let window = Surface(name: "Window", shape: .quad, mesh: .rect(center: SIMD2(0.72, 0.35), size: SIMD2(0.2, 0.3)))
        let porch = Surface(name: "Porch arch", shape: .circle, mesh: .rect(center: SIMD2(0.72, 0.75), size: SIMD2(0.25, 0.3)))
        p.surfaces = [wall, window, porch]

        func preset(_ id: String) -> Layer { PresetLibrary.all.first { $0.id == id }!.makeLayer() }
        var halloween = MapScene(name: "Halloween")
        halloween.assignments[wall.id] = SurfaceContent(layers: [preset("hw.fog"), preset("hw.lightning")])
        halloween.assignments[window.id] = SurfaceContent(layers: [preset("hw.eyes")])
        halloween.assignments[porch.id] = SurfaceContent(layers: [preset("hw.fire")])
        var xmas = MapScene(name: "Christmas")
        xmas.assignments[wall.id] = SurfaceContent(layers: [preset("xm.snow")])
        xmas.assignments[window.id] = SurfaceContent(layers: [preset("xm.warmlights")])
        xmas.assignments[porch.id] = SurfaceContent(layers: [preset("xm.candy")])
        var party = MapScene(name: "Party")
        party.assignments[wall.id] = SurfaceContent(layers: [preset("audio.spectrum")])
        party.assignments[window.id] = SurfaceContent(layers: [preset("vj.tunnel.cyan")])
        party.assignments[porch.id] = SurfaceContent(layers: [preset("audio.rings")])
        p.scenes = [halloween, xmas, party]
        p.activeSceneID = halloween.id
        p.timeline.clips = [
            TimelineClip(sceneID: halloween.id, start: 0, duration: 16),
            TimelineClip(sceneID: xmas.id, start: 16, duration: 16),
            TimelineClip(sceneID: party.id, start: 32, duration: 16),
        ]
        return p
    }
}

struct ReceiverView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var link = LinkService(role: .receiver)
    @State private var showURL: URL? = LinkService.latestReceivedShow()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let showURL {
                LoopingPlayer(url: showURL).ignoresSafeArea().id(showURL)
            }
            VStack {
                HStack {
                    Button("Exit") { model.receiverMode = false }.buttonStyle(.bordered)
                    Spacer()
                    if let p = link.transferProgress { ProgressView(value: p).frame(width: 160) }
                    Text(link.status).font(.caption)
                }
                .padding()
                .background(.black.opacity(0.4))
                Spacer()
                if showURL == nil {
                    Text("Waiting for a show from Lightmapping on another device…").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            link.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            link.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: link.lastReceived) { _, url in if let url { showURL = url } }
    }
}
